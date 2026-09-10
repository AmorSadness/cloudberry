#!/usr/bin/env python3
"""Manual GPU acceptance. Uses psql only; never reports a native plan as GPU success."""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import time
import uuid


def main():
    if not __debug__:
        raise SystemExit("Run without Python -O/PYTHONOPTIMIZE: acceptance assertions are required")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=["mixed", "aggregates", "unfiltered", "redistribute",
                        "count_types", "host_input", "cpu_filter", "heap_partition", "operators", "all"], default="all")
    parser.add_argument("--normal-planner", action="store_true",
                        help="leave cost and native path settings unchanged; GPU plan assertions still apply")
    parser.add_argument("--expansion-failure", action="store_true",
                        help="superuser-only: force underestimated mixed groups and inject replacement allocation failure")
    parser.add_argument("--rescan", action="store_true",
                        help="require actual repeated GpuPreAgg loops for a correlated mixed subquery")
    args = parser.parse_args()
    out = Path(os.environ.get("PGSTROM_RESULTS", f"/tmp/pgstrom-development-{uuid.uuid4().hex}"))
    out.mkdir(parents=True, exist_ok=False)
    schema = "pgstrom_dev_" + uuid.uuid4().hex
    injection_armed = False
    command = [os.environ.get("PSQL", "psql"), "-X", "-q", "-A", "-t",
               "-v", "ON_ERROR_STOP=1", "-d", os.environ.get("PGDATABASE", "postgres")]
    settings = """
      SET optimizer=off; SET statement_timeout='120s';
      SET pg_strom.enabled=on; SET pg_strom.enable_gpuscan=on;
      SET pg_strom.enable_gpupreagg=on; SET pg_strom.cpu_fallback=off;
      SET pg_strom.cloudberry_enable_host_quals=on;
      SET pg_strom.cloudberry_enable_extended_agg=off;
      SET pg_strom.cloudberry_enable_unfiltered_agg=off;
      SET pg_strom.cloudberry_enable_redistribute_final=off;
      SET pg_strom.cloudberry_enable_count_types=off;
      SET pg_strom.cloudberry_enable_host_input=off;
      SET pg_strom.cloudberry_enable_cpu_filter=off;
      SET pg_strom.cloudberry_enable_heap_partition=off;
    """
    if not args.normal_planner:
        settings += """
          SET gp_enable_multiphase_agg=off; SET enable_seqscan=off;
          SET pg_strom.gpu_setup_cost=0; SET pg_strom.gpu_tuple_cost=0;
          SET pg_strom.gpu_operator_cost=0;
        """

    def sql(query, prefix=""):
        result = subprocess.run(command, input=prefix + query, text=True,
                                capture_output=True, timeout=150)
        if result.returncode:
            raise RuntimeError(result.stderr + "\nSQL: " + query)
        return result.stdout.strip()

    def nodes(plan):
        yield plan
        for child in plan.get("Plans", []):
            yield from nodes(child)

    def check(label, query, extra="", mixed=False, native=False, redistribute=False,
              no_redistribute=False, local_final=False, float_columns=(), cpu_input=False):
        prefix = settings + extra
        raw = sql("EXPLAIN (ANALYZE, VERBOSE, FORMAT JSON) " + query, prefix)
        (out / (label + ".plan.json")).write_text(raw + "\n")
        plan = json.loads(raw)[0]["Plan"]
        all_nodes = list(nodes(plan))
        gpu = [n for n in all_nodes if n.get("Custom Plan Provider") == "GpuPreAgg"]
        if native:
            assert not gpu, label + ": expected native fallback"
        else:
            assert gpu, label + ": GpuPreAgg absent"
        if mixed:
            assert "CPU host-filtered GpuScan rows" in raw, label + ": mixed input absent"
            for parent in gpu:
                assert any(n.get("Custom Plan Provider") == "GpuScan" and "Filter" in n
                           for n in nodes(parent)), label + ": host filter not below preaggregation"
        if cpu_input:
            assert gpu and all(n.get("Pre-Aggregation Input") ==
                               "Native CPU scan/filter/projection rows" for n in gpu), label
            assert all(any(c.get("Node Type") in ("Seq Scan", "Index Scan", "Index Only Scan", "Bitmap Heap Scan")
                           for c in nodes(n)) for n in gpu), label + ": native input absent"
            assert not any(n.get("Custom Plan Provider") == "GpuScan" for n in all_nodes), label
        if redistribute:
            # The Redistribute must be below final Agg and above GPU partial.
            assert any("Redistribute" in n.get("Node Type", "") and n.get("Receivers", 0) >= 2 and
                       any(c.get("Custom Plan Provider") == "GpuPreAgg" for c in nodes(n))
                       for n in all_nodes), label + ": Redistribute below final absent"
        if no_redistribute:
            assert not any("Redistribute" in n.get("Node Type", "") for n in all_nodes), label
        if local_final:
            # The final result may Gather above Agg, but partial rows must not.
            assert any(n.get("Node Type") == "Aggregate" and
                       any(c.get("Custom Plan Provider") == "GpuPreAgg" for c in nodes(n)) and
                       not any("Motion" in c.get("Node Type", "") for c in nodes(n))
                       for n in all_nodes), label + ": local final absent"
        ordered = "SELECT row_to_json(q)::text FROM (" + query + ") q ORDER BY 1"
        cpu = sql(ordered, "SET optimizer=off; SET pg_strom.enabled=off;")
        for repeat in range(3):
            actual = sql(ordered, prefix)
            (out / f"{label}.{repeat}.result").write_text(actual + "\n")
            if float_columns:
                cpu_rows = [json.loads(line) for line in cpu.splitlines()]
                gpu_rows = [json.loads(line) for line in actual.splitlines()]
                assert len(cpu_rows) == len(gpu_rows), label + ": row count mismatch"
                for expected, observed in zip(cpu_rows, gpu_rows):
                    assert expected.keys() == observed.keys(), label
                    for column, value in expected.items():
                        other = observed[column]
                        if column in float_columns and isinstance(value, (int, float)):
                            assert isinstance(other, (int, float)) and math.isclose(
                                value, other, rel_tol=1e-10, abs_tol=1e-12), label + ": float mismatch"
                        else:
                            assert value == other, label + ": non-float/NULL/special mismatch"
            else:
                assert actual == cpu, label + ": CPU/GPU mismatch"
        print(label + ": PASS", flush=True)

    try:
        deadline = time.monotonic() + 120
        while True:
            ready = sql("""SELECT count(DISTINCT content_id) >= 3
              AND bool_and(ready AND actual_workers = configured_workers)
              FROM pgstrom.gpu_service_status""")
            if ready == "t":
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("QD and at least two Primary GPU Services must be ready")
            time.sleep(0.5)
        (out / "environment.txt").write_text(sql("""
          SELECT version(); SELECT extversion FROM pg_extension WHERE extname='pg_strom';
          SELECT row_to_json(s) FROM pgstrom.gpu_service_status s;
          SELECT name,setting FROM pg_settings WHERE name LIKE 'pg_strom.%'
             OR name IN ('optimizer','gp_enable_multiphase_agg','enable_seqscan','gp_motion_cost_per_row');
        """))
        sql(f"""
          CREATE SCHEMA {schema};
          CREATE TABLE {schema}.data (id int, grp int, v int, f float8,
            payload text, unused int) DISTRIBUTED BY (id);
          INSERT INTO {schema}.data
          SELECT i, CASE WHEN i%17=0 THEN NULL ELSE i%127 END,
            CASE WHEN i%13=0 THEN NULL ELSE i%1000-500 END,
            CASE WHEN i%13=0 THEN NULL ELSE (i%1000-500)::float8 END,
            CASE WHEN i%19=0 THEN NULL ELSE repeat(md5(i::text),128) END, 1
          FROM generate_series(1,100000) i;
          ALTER TABLE {schema}.data DROP COLUMN unused;
          ALTER TABLE {schema}.data ADD COLUMN missing int DEFAULT 7;
          ANALYZE {schema}.data;
        """)
        table = schema + ".data"
        if args.stage in ("mixed", "all"):
            for label, where in [("wide_chunks", "payload ~ '^[0-7]'"),
                                 ("empty", "payload ~ '^impossible'"),
                                 ("nulls", "payload IS NULL AND v::text ~ '^-'")]:
                check("mixed_" + label,
                      f"SELECT grp,count(*),sum(v),min(v),max(v) FROM {table} "
                      f"WHERE id>0 AND {where} GROUP BY grp", mixed=True)
            # A referenced missing-value attribute must fall back safely.
            check("mixed_missing", f"SELECT grp,sum(missing) FROM {table} "
                  "WHERE id>0 AND payload ~ '^[0-7]' GROUP BY grp", native=True)
            # FORCE_GENERIC_PLAN exercises dispatched Params repeatedly in one session.
            query = f"SELECT grp,count(*),sum(v) FROM {table} WHERE id>$1 AND payload ~ '^[0-7]' GROUP BY grp"
            prepared = "SET plan_cache_mode=force_generic_plan; PREPARE dev(int) AS " + query + ";"
            raw = sql(prepared + "EXPLAIN (VERBOSE, FORMAT JSON) EXECUTE dev(0); DEALLOCATE dev;", settings)
            (out / "mixed_prepared.plan.json").write_text(raw)
            assert "CPU host-filtered GpuScan rows" in raw
            # Ordering outside the prepared statement avoids unstable group order.
            prepared = prepared.replace(" GROUP BY grp;", " GROUP BY grp ORDER BY grp NULLS FIRST;")
            executions = "EXECUTE dev(0); EXECUTE dev(50000); EXECUTE dev(100001); EXECUTE dev(0); DEALLOCATE dev;"
            assert sql(prepared + executions, settings) == sql(prepared + executions,
                "SET optimizer=off; SET pg_strom.enabled=off;")
            print("mixed_prepared: PASS", flush=True)
        if args.rescan:
            query = f"SELECT p.id, a.n FROM (VALUES (1),(2),(3)) p(id) CROSS JOIN LATERAL " \
                    f"(SELECT count(*) AS n FROM {table} t WHERE t.id>p.id AND t.payload ~ '^[0-7]') a"
            extra = "SET enable_material=off; SET enable_hashjoin=off; SET enable_mergejoin=off;"
            check("mixed_rescan", query, extra, mixed=True)
            plan = json.loads((out / "mixed_rescan.plan.json").read_text())[0]["Plan"]
            assert any(n.get("Custom Plan Provider") == "GpuPreAgg" and n.get("Actual Loops", 0)>1
                       for n in nodes(plan)), "query did not exercise executor rescan; not an accepted rescan test"
        extended = "SET pg_strom.cloudberry_enable_extended_agg=on;"
        if args.stage in ("aggregates", "all"):
            # Integer-valued float input keeps this exact result oracle stable;
            # non-exact floating input should use an explicit tolerance oracle.
            for label, where in [("groups", "id>0"), ("empty", "id>100001"),
                                 ("null", "id>0 AND v IS NULL"),
                                 ("mixed", "id>0 AND payload ~ '^[0-7]'")]:
                check("avg_" + label, f"SELECT grp,avg(v::int2) AS a2,avg(v) AS a4,"
                      f"avg(v::int8) AS a8,avg(f::float4) AS f4,avg(f) AS f8 FROM {table} "
                      f"WHERE {where} GROUP BY grp", extended, mixed=label == "mixed")
            check("filter", f"SELECT grp,count(*) FILTER (WHERE v>0) AS n,"
                  "sum(v) FILTER (WHERE v<0) AS s,min(v) FILTER (WHERE v>0) AS lo,"
                  "max(v) FILTER (WHERE v>0) AS hi,avg(v) FILTER (WHERE v>0) AS a,"
                  "count(*) FILTER (WHERE v IS NULL) AS nulls,"
                  "count(*) FILTER (WHERE NULL::boolean) AS unknown "
                  f"FROM {table} WHERE id>0 GROUP BY grp "
                  "HAVING avg(v) FILTER (WHERE v>0)>0", extended)
            check("filter_false_global", f"SELECT count(*) FILTER (WHERE false) AS n,"
                  f"avg(v) FILTER (WHERE false) AS a FROM {table} WHERE id>0", extended)
            check("filter_preserves_groups", f"SELECT grp,count(*) FILTER (WHERE false) AS n,"
                  f"sum(v) FILTER (WHERE NULL::boolean) AS s FROM {table} WHERE id>0 GROUP BY grp", extended)
            check("avg_global_empty", f"SELECT avg(v),count(*) FROM {table} WHERE id>100001", extended)
            check("avg_off", f"SELECT avg(v) FROM {table} WHERE id>0", native=True)
            check("filter_off", f"SELECT count(*) FILTER (WHERE v>0) FROM {table} WHERE id>0", native=True)
            check("filter_host_fallback", f"SELECT count(*) FILTER (WHERE payload ~ '^[0-7]') "
                  f"FROM {table} WHERE id>0", extended, native=True)
            check("numeric_fallback", f"SELECT avg(v::numeric) FROM {table} WHERE id>0", extended, native=True)
            check("distinct_fallback", f"SELECT count(DISTINCT v) FROM {table} WHERE id>0", extended, native=True)
            sql(f"UPDATE {table} SET f=v::float8/7.0;")
            check("avg_fractional", f"SELECT grp,avg(f) AS a FROM {table} WHERE id>0 GROUP BY grp",
                  extended, float_columns=("a",))
            sql(f"""CREATE TABLE {schema}.bounds (id int,grp int,v int8,f float8) DISTRIBUTED BY (id);
              INSERT INTO {schema}.bounds SELECT i,i%4,
                CASE WHEN i%3=0 THEN '9223372036854775807'::int8
                     WHEN i%3=1 THEN '-9223372036854775808'::int8 ELSE NULL END,
                CASE WHEN i%4=0 THEN 'NaN'::float8 WHEN i%4=1 THEN 'Infinity'::float8
                     WHEN i%4=2 THEN '-Infinity'::float8 ELSE NULL END
              FROM generate_series(1,10000) i;
              ANALYZE {schema}.bounds;""")
            check("avg_boundaries", f"SELECT grp,avg(v) AS a,avg(f) AS f FROM {schema}.bounds WHERE id>0 GROUP BY grp",
                  extended)
        unfiltered = "SET pg_strom.cloudberry_enable_unfiltered_agg=on;"
        if args.stage in ("unfiltered", "all"):
            check("unfiltered_global", f"SELECT count(*),sum(v),min(v),max(v) FROM {table}", unfiltered)
            check("unfiltered_group", f"SELECT grp,count(*),sum(v) FROM {table} GROUP BY grp", unfiltered)
            check("unfiltered_avg_filter", f"SELECT grp,avg(v) FILTER (WHERE v>0) FROM {table} GROUP BY grp",
                  unfiltered + extended)
            check("unfiltered_off", f"SELECT count(*) FROM {table}", native=True)
            check("host_only", f"SELECT count(*) FROM {table} WHERE payload ~ '^[0-7]'", unfiltered, native=True)
            sql(f"CREATE TABLE {schema}.empty (LIKE {table}) DISTRIBUTED BY (id); ANALYZE {schema}.empty;")
            check("unfiltered_empty", f"SELECT count(*),sum(v) FROM {schema}.empty", unfiltered)
            raw = sql(f"EXPLAIN (FORMAT JSON) SELECT id FROM {table}", settings + unfiltered)
            assert "GpuScan" not in raw, "unfiltered opt-in unexpectedly enabled standalone GpuScan"
            all_features = extended + unfiltered + "SET pg_strom.cloudberry_enable_redistribute_final=on;"
            check("orca_fallback", f"SELECT grp,avg(v) FROM {table} GROUP BY grp",
                  all_features + "SET optimizer=on;", native=True)
            check("grouping_sets_fallback", f"SELECT grp,count(*) FROM {table} GROUP BY GROUPING SETS ((grp),())",
                  all_features, native=True)
            for storage, options in [("ao", "appendonly=true,orientation=row"),
                                     ("aoco", "appendonly=true,orientation=column")]:
                sql(f"CREATE TABLE {schema}.{storage} (LIKE {table}) WITH ({options}) DISTRIBUTED BY (id); "
                    f"INSERT INTO {schema}.{storage} SELECT * FROM {table} LIMIT 100; ANALYZE {schema}.{storage};")
                check(storage + "_fallback", f"SELECT grp,avg(v) FROM {schema}.{storage} GROUP BY grp",
                      all_features, native=True)
            sql(f"CREATE TABLE {schema}.parts (LIKE {table}) DISTRIBUTED BY (id) PARTITION BY RANGE (id); "
                f"CREATE TABLE {schema}.part1 PARTITION OF {schema}.parts FOR VALUES FROM (1) TO (100001); "
                f"INSERT INTO {schema}.parts SELECT * FROM {table} LIMIT 100; ANALYZE {schema}.parts;")
            check("partition_fallback", f"SELECT grp,avg(v) FROM {schema}.parts GROUP BY grp", all_features, native=True)
            sql(f"CREATE TABLE {schema}.replicated (LIKE {table}) DISTRIBUTED REPLICATED; "
                f"INSERT INTO {schema}.replicated SELECT * FROM {table} LIMIT 100; ANALYZE {schema}.replicated;")
            check("replicated_fallback", f"SELECT grp,avg(v) FROM {schema}.replicated GROUP BY grp", all_features, native=True)
        redistribution = "SET pg_strom.cloudberry_enable_redistribute_final=on;"
        if args.stage in ("redistribute", "all"):
            # Larger NDV makes parallel CPU final useful while partial reduction
            # remains below the conservative 50% eligibility threshold.
            sql(f"UPDATE {table} SET grp=id%4096; ANALYZE {table};")
            query = f"SELECT grp,count(*),sum(v) FROM {table} WHERE id>0 GROUP BY grp"
            check("redistribute_groups", query, redistribution, redistribute=True)
            check("redistribute_multi_key", f"SELECT grp,v%2 AS k,count(*) FROM {table} "
                  "WHERE id>0 GROUP BY grp,v%2", redistribution, redistribute=True)
            check("redistribute_off", query, no_redistribute=True)
            check("redistribute_mixed_having", f"SELECT grp,avg(v) FILTER (WHERE v>0) AS a "
                  f"FROM {table} WHERE id>0 AND payload ~ '^[0-7]' GROUP BY grp "
                  "HAVING count(*)>1", redistribution + extended, mixed=True, redistribute=True)
            check("redistribute_unfiltered", f"SELECT grp,count(*) FROM {table} GROUP BY grp",
                  redistribution + unfiltered, redistribute=True)
            check("redistribute_global", f"SELECT count(*) FROM {table} WHERE id>0", redistribution,
                  no_redistribute=True)
            sql(f"CREATE TABLE {schema}.colocated (dist_key int,v int) DISTRIBUTED BY (dist_key); "
                f"INSERT INTO {schema}.colocated SELECT id%127,v FROM {table}; ANALYZE {schema}.colocated;")
            check("redistribute_colocated", f"SELECT dist_key,count(*) FROM {schema}.colocated WHERE v>=-500 GROUP BY dist_key",
                  redistribution, no_redistribute=True, local_final=True)
            sql(f"UPDATE {table} SET grp=NULL WHERE id%3=0; ANALYZE {table};")
            check("redistribute_null_skew", query, redistribution, redistribute=True)
        count_types = "SET pg_strom.cloudberry_enable_count_types=on;"
        host_input = "SET pg_strom.cloudberry_enable_host_input=on;"
        cpu_filter = "SET pg_strom.cloudberry_enable_cpu_filter=on;"
        heap_partition = "SET pg_strom.cloudberry_enable_heap_partition=on;"
        operator_features = count_types + host_input + cpu_filter + heap_partition + extended + unfiltered
        if args.stage in ("count_types", "operators", "all"):
            sql(f"""CREATE TABLE {schema}.typed (id int,grp int,b bool,t text,vc varchar(12),
              ch char(12),bin bytea,n numeric,d date,tm time,tz timetz,ts timestamp,
              tstz timestamptz,iv interval,u uuid,ip inet,mac macaddr,j jsonb)
              DISTRIBUTED BY (id);
              INSERT INTO {schema}.typed
              SELECT i,i%17,i%2=0,repeat(md5(i::text),128),substr(md5(i::text),1,12),
                'abc',decode(md5(i::text),'hex'),i::numeric/7,
                date '2024-01-01'+i%365,time '12:34:56',timetz '12:34:56+08',
                timestamp '2024-01-01 12:00:00',timestamptz '2024-01-01 12:00:00+00',
                interval '2 days',md5(i::text)::uuid,'127.0.0.1'::inet,
                '08:00:2b:01:02:03'::macaddr,jsonb_build_object('v',i)
              FROM generate_series(1,60000) i;
              UPDATE {schema}.typed SET b=NULL,t=NULL,vc=NULL,ch=NULL,bin=NULL,n=NULL,d=NULL,
                tm=NULL,tz=NULL,ts=NULL,tstz=NULL,iv=NULL,u=NULL,ip=NULL,mac=NULL,j=NULL WHERE id%13=0;
              ANALYZE {schema}.typed;""")
            cols = ["b", "t", "vc", "ch", "bin", "n", "d", "tm", "tz", "ts", "tstz", "iv", "u", "ip", "mac", "j"]
            counts = ",".join(f"count({c}) AS c_{c}" for c in cols)
            for label, where in [("groups", "id>0"), ("all_null", "id>0 AND id%13=0"),
                                 ("empty", "id>60001")]:
                check("count_types_" + label, f"SELECT grp,{counts} FROM {schema}.typed "
                      f"WHERE {where} GROUP BY grp", count_types)
            check("count_types_global_empty", f"SELECT {counts} FROM {schema}.typed WHERE id>60001", count_types)
            check("count_types_off", f"SELECT count(t) FROM {schema}.typed WHERE id>0", native=True)
            check("count_types_cpu_chunks", f"SELECT grp,count(t) AS n FROM {schema}.typed "
                  "WHERE t ~ '^[0-9a-f]' GROUP BY grp", count_types + host_input, cpu_input=True)
            for label, expr in [("array", "ARRAY[v]"), ("row", "ROW(grp,v)"), ("xml", "xmlparse(content '<x/>')")]:
                check("count_" + label + "_fallback", f"SELECT count({expr}) FROM {table} WHERE id>0",
                      operator_features, native=True)
            check("count_distinct_fallback", f"SELECT count(DISTINCT payload) FROM {table} WHERE id>0",
                  operator_features, native=True)
            check("numeric_sum_still_native", f"SELECT sum(v::numeric) FROM {table} WHERE id>0",
                  operator_features, native=True)
        if args.stage in ("host_input", "operators", "all"):
            for label, pred in [("groups", "payload ~ '^[0-7]'"), ("empty", "payload ~ '^impossible'")]:
                check("host_input_" + label, f"SELECT grp,count(*) AS n,sum(v) AS s,min(v) AS lo,max(v) AS hi "
                      f"FROM {table} WHERE {pred} GROUP BY grp", host_input, cpu_input=True)
            check("host_input_global", f"SELECT count(*) AS n,sum(v) AS s FROM {table} WHERE payload ~ '^[0-7]'",
                  host_input, cpu_input=True)
            check("host_input_missing", f"SELECT grp,sum(missing) AS s FROM {table} WHERE payload ~ '^[0-7]' GROUP BY grp",
                  host_input, cpu_input=True)
            check("host_input_off", f"SELECT count(*) FROM {table} WHERE payload ~ '^[0-7]'", native=True)
            raw = sql(f"EXPLAIN (FORMAT JSON) SELECT id FROM {table} WHERE payload ~ '^[0-7]'", settings + host_input)
            assert "GpuScan" not in raw and "GpuPreAgg" not in raw, "host-input switch enabled standalone scan"
            prepared_query = f"SELECT grp,count(*) AS n FROM {table} WHERE payload ~ $1 GROUP BY grp ORDER BY grp NULLS FIRST"
            prepared = "SET plan_cache_mode=force_generic_plan; PREPARE hostq(text) AS " + prepared_query + ";"
            raw = sql(prepared + "EXPLAIN (ANALYZE, FORMAT JSON) EXECUTE hostq('^[0-7]'); DEALLOCATE hostq;",
                      settings + host_input)
            (out / "host_input_prepared.plan.json").write_text(raw)
            assert "Native CPU scan/filter/projection rows" in raw
            executions = "EXECUTE hostq('^[0-7]'); EXECUTE hostq(NULL); EXECUTE hostq('^impossible'); EXECUTE hostq('^[0-7]'); DEALLOCATE hostq;"
            assert sql(prepared + executions, settings + host_input) == sql(
                prepared + executions, "SET optimizer=off; SET pg_strom.enabled=off;")
            print("host_input_prepared: PASS", flush=True)
        if args.stage in ("cpu_filter", "operators", "all"):
            check("cpu_filter_independent", f"SELECT grp,count(*) AS all_n,"
                  "count(*) FILTER (WHERE payload ~ '^[0-7]') AS n,"
                  "count(v) FILTER (WHERE payload ~ '^[8-f]') AS vn,"
                  "sum(v) FILTER (WHERE payload ~ '^[0-7]') AS s,"
                  "avg(v) FILTER (WHERE payload ~ '^[8-f]') AS a,"
                  "min(v) FILTER (WHERE payload ~ '^impossible') AS lo,"
                  "max(v) FILTER (WHERE payload ~ '^impossible') AS hi "
                  f"FROM {table} WHERE id>0 GROUP BY grp HAVING count(*) FILTER (WHERE payload ~ '^[0-f]')>0",
                  cpu_filter + extended, cpu_input=True)
            check("cpu_filter_empty", f"SELECT count(*) FILTER (WHERE payload ~ 'x') AS n,"
                  f"sum(v) FILTER (WHERE payload ~ 'x') AS s FROM {table} WHERE id>100001",
                  cpu_filter, cpu_input=True)
            check("cpu_filter_unknown", f"SELECT grp,count(*) FILTER (WHERE payload ~ 'x') AS n,"
                  f"sum(v) FILTER (WHERE payload ~ 'x') AS s FROM {table} WHERE id>0 AND payload IS NULL GROUP BY grp",
                  cpu_filter, cpu_input=True)
            check("cpu_filter_short_circuit", f"SELECT grp,sum(100/(id-id)) FILTER (WHERE payload ~ '^impossible') AS s "
                  f"FROM {table} WHERE id>0 GROUP BY grp", cpu_filter, cpu_input=True)
            check("cpu_filter_mixed_device", f"SELECT grp,count(*) FILTER (WHERE payload ~ '^[0-7]') AS n,"
                  f"sum(v) FILTER (WHERE v>0) AS s FROM {table} WHERE id>0 GROUP BY grp", cpu_filter, cpu_input=True)
            check("cpu_filter_host_where", f"SELECT grp,count(*) FILTER (WHERE v::text ~ '^-') AS n "
                  f"FROM {table} WHERE payload ~ '^[0-7]' GROUP BY grp", cpu_filter + host_input, cpu_input=True)
            check("cpu_filter_unfiltered", f"SELECT count(*) FILTER (WHERE payload ~ '^[0-7]') FROM {table}",
                  cpu_filter + unfiltered, cpu_input=True)
            check("cpu_filter_off", f"SELECT count(*) FILTER (WHERE payload ~ 'x') FROM {table} WHERE id>0",
                  extended, native=True)
            # Use EXPLAIN only for volatile expressions: independently running CPU and GPU cannot be an equality oracle.
            raw = sql(f"EXPLAIN (FORMAT JSON) SELECT count(*) FILTER (WHERE payload ~ 'x' OR random()>0.5) "
                      f"FROM {table} WHERE id>0", settings + operator_features)
            (out / "cpu_filter_volatile.plan.json").write_text(raw)
            assert "GpuPreAgg" not in raw, "volatile FILTER must retain native aggregation"
            check("cpu_filter_subplan_fallback", f"SELECT count(*) FILTER (WHERE payload ~ "
                  f"(SELECT x FROM (VALUES ('x'::text)) q(x) OFFSET 0)) FROM {table} WHERE id>0",
                  cpu_filter, native=True)
            error_query = f"SELECT sum(100/(id-id)) FILTER (WHERE payload ~ '^[0-9a-f]') FROM {table} WHERE id>0"
            raw = sql("EXPLAIN (FORMAT JSON) " + error_query, settings + cpu_filter)
            (out / "cpu_filter_error.plan.json").write_text(raw)
            assert "Native CPU scan/filter/projection rows" in raw
            failed = subprocess.run(command, input=settings + cpu_filter + error_query,
                                    text=True, capture_output=True, timeout=150)
            (out / "cpu_filter_error.err").write_text(failed.stderr)
            assert failed.returncode and "division by zero" in failed.stderr and not failed.stdout.strip(), \
                "true FILTER must propagate the CPU argument error without partial results"
            check("cpu_filter_error_recovery", f"SELECT count(*) FILTER (WHERE payload ~ '^[0-7]') FROM {table} WHERE id>0",
                  cpu_filter, cpu_input=True)
        if args.stage in ("heap_partition", "operators", "all"):
            sql(f"""CREATE TABLE {schema}.hp (id int,grp int,v int,payload text,missing int DEFAULT 7)
              DISTRIBUTED BY (id) PARTITION BY RANGE(id);
              CREATE TABLE {schema}.hp_low PARTITION OF {schema}.hp FOR VALUES FROM (1) TO (40001);
              CREATE TABLE {schema}.hp_high PARTITION OF {schema}.hp FOR VALUES FROM (40001) TO (100001);
              CREATE TABLE {schema}.hp_default PARTITION OF {schema}.hp DEFAULT;
              INSERT INTO {schema}.hp SELECT id,grp,v,payload,missing FROM {table};
              ANALYZE {schema}.hp;""")
            hp = schema + ".hp"
            check("heap_partition_all", f"SELECT grp,count(*) AS n,sum(v) AS s FROM {hp} WHERE id>0 GROUP BY grp",
                  heap_partition, cpu_input=True)
            check("heap_partition_pruned", f"SELECT grp,count(*) AS n FROM {hp} WHERE id>0 AND id<40001 GROUP BY grp",
                  heap_partition, cpu_input=True)
            raw = (out / "heap_partition_pruned.plan.json").read_text()
            assert '"Relation Name": "hp_high"' not in raw and '"Relation Name": "hp_default"' not in raw, "static pruning absent"
            check("heap_partition_empty_default", f"SELECT count(*) AS n,sum(v) AS s FROM {hp} WHERE id>100000",
                  heap_partition, cpu_input=True)
            check("heap_partition_host_filter", f"SELECT grp,count(payload) FILTER (WHERE v::text ~ '^-') AS n,"
                  f"avg(v) FILTER (WHERE payload ~ '^[0-7]') AS a FROM {hp} WHERE payload ~ '^[0-7]' GROUP BY grp",
                  operator_features, cpu_input=True)
            check("heap_partition_no_qual", f"SELECT count(*) AS n,sum(missing) AS s FROM {hp}",
                  heap_partition + unfiltered, cpu_input=True)
            check("heap_partition_off", f"SELECT count(*) FROM {hp} WHERE id>0", native=True)
            # Attached leaf has a different physical column order and a dropped attribute.
            sql(f"""CREATE TABLE {schema}.hp_reordered (payload text,obsolete int,v int,id int,grp int,missing int DEFAULT 7)
              DISTRIBUTED BY (id);
              ALTER TABLE {schema}.hp_reordered DROP COLUMN obsolete;
              ALTER TABLE {hp} ATTACH PARTITION {schema}.hp_reordered FOR VALUES FROM (100001) TO (110001);
              INSERT INTO {hp} SELECT i,i%17,i%101,md5(i::text),7 FROM generate_series(100001,110000) i;
              ALTER TABLE {hp} ADD COLUMN added int DEFAULT 9;
              ANALYZE {hp};""")
            check("heap_partition_column_mapping", f"SELECT grp,count(*) AS n,sum(added) AS s,sum(missing) AS m "
                  f"FROM {hp} WHERE id>0 GROUP BY grp", heap_partition, cpu_input=True)
            prepared = f"SET plan_cache_mode=force_generic_plan; PREPARE partq(int,int) AS SELECT grp,count(*) AS n,sum(v) AS s FROM {hp} WHERE id >= $1 AND id < $2 GROUP BY grp ORDER BY grp NULLS FIRST;"
            raw = sql(prepared + "EXPLAIN (ANALYZE, VERBOSE, FORMAT JSON) EXECUTE partq(1,40001); DEALLOCATE partq;",
                      settings + heap_partition)
            (out / "heap_partition_prepared.plan.json").write_text(raw)
            assert "Native CPU scan/filter/projection rows" in raw
            plan_nodes = list(nodes(json.loads(raw)[0]["Plan"]))
            assert not any(n.get("Relation Name") in ("hp_high", "hp_reordered", "hp_default") and
                           n.get("Actual Loops", 0)>0 for n in plan_nodes), "runtime partition pruning absent"
            executions = "EXECUTE partq(1,40001); EXECUTE partq(40001,100001); EXECUTE partq(100001,110001); EXECUTE partq(200000,300000); DEALLOCATE partq;"
            assert sql(prepared + executions, settings + heap_partition) == sql(
                prepared + executions, "SET optimizer=off; SET pg_strom.enabled=off;")
            print("heap_partition_prepared: PASS", flush=True)
            sql(f"INSERT INTO {hp} (id,grp,v,payload) SELECT i,i%17,i%101,md5(i::text) "
                f"FROM generate_series(200000,201000) i; ANALYZE {hp};")
            check("heap_partition_default_rows", f"SELECT grp,count(*) AS n,sum(v) AS s FROM {hp} "
                  "WHERE id>=200000 GROUP BY grp", heap_partition, cpu_input=True)
            sql(f"""CREATE TABLE {schema}.nested (id int,grp int,v int) DISTRIBUTED BY (id) PARTITION BY RANGE(id);
              CREATE TABLE {schema}.nested_range PARTITION OF {schema}.nested FOR VALUES FROM (1) TO (10001)
                PARTITION BY LIST(grp);
              CREATE TABLE {schema}.nested_zero PARTITION OF {schema}.nested_range FOR VALUES IN (0);
              CREATE TABLE {schema}.nested_rest PARTITION OF {schema}.nested_range DEFAULT;
              INSERT INTO {schema}.nested SELECT i,i%17,i%101 FROM generate_series(1,10000) i;
              ANALYZE {schema}.nested;""")
            check("heap_partition_nested", f"SELECT grp,count(*) AS n,sum(v) AS s FROM {schema}.nested WHERE id>0 GROUP BY grp",
                  heap_partition, cpu_input=True)
            sql(f"""CREATE TABLE {schema}.inherit_root (id int,v int) DISTRIBUTED BY (id);
              CREATE TABLE {schema}.inherit_child () INHERITS ({schema}.inherit_root) DISTRIBUTED BY (id);
              INSERT INTO {schema}.inherit_child SELECT i,i FROM generate_series(1,1000) i;
              ANALYZE {schema}.inherit_root;""")
            check("traditional_inheritance_fallback", f"SELECT count(*) FROM {schema}.inherit_root WHERE id>0",
                  operator_features, native=True)
            for storage, options, policy in [("ao", "WITH (appendonly=true,orientation=row)", "BY (id)"),
                                              ("aoco", "WITH (appendonly=true,orientation=column)", "BY (id)"),
                                              ("repl", "", "REPLICATED")]:
                fixture = schema + ".operator_" + storage
                sql(f"CREATE TABLE {fixture} (LIKE {table}) {options} DISTRIBUTED {policy}; "
                    f"INSERT INTO {fixture} SELECT * FROM {table} LIMIT 100; ANALYZE {fixture};")
                check("operator_" + storage + "_fallback", f"SELECT count(payload) FILTER (WHERE payload ~ 'x') "
                      f"FROM {fixture} WHERE payload ~ 'x'", operator_features, native=True)
            # Conservatively reject the whole tree, even if the non-heap leaf is pruned.
            sql(f"""CREATE TABLE {schema}.hp_ao PARTITION OF {hp} FOR VALUES FROM (110001) TO (120001)
              WITH (appendonly=true,orientation=row); ANALYZE {hp};""")
            check("heap_partition_ao_leaf_fallback", f"SELECT count(*) FROM {hp} WHERE id>0 AND id<40001",
                  operator_features, native=True)
            check("operators_orca_fallback", f"SELECT grp,count(payload) FROM {table} WHERE payload ~ 'x' GROUP BY grp",
                  operator_features + "SET optimizer=on;", native=True)
        if args.expansion_failure:
            # Deliberately stale NDV forces the production geometric expansion.
            # A narrow fixture bounds host storage while providing enough actual groups.
            sql(f"""CREATE TABLE {schema}.growth (id int, grp int, payload text) DISTRIBUTED BY (id);
              INSERT INTO {schema}.growth SELECT i, i%1000000, md5(i::text)
              FROM generate_series(1,2000000) i;
              ALTER TABLE {schema}.growth ALTER COLUMN grp SET (n_distinct=1);
              ANALYZE {schema}.growth;""")
            query = f"SELECT grp,count(*) AS n,sum(id) AS s,min(id) AS lo,max(id) AS hi FROM {schema}.growth " \
                    "WHERE id>0 AND payload ~ '^[0-7]' GROUP BY grp"
            plan = sql("EXPLAIN (VERBOSE, FORMAT JSON) " + query, settings)
            (out / "expansion.plan.json").write_text(plan)
            assert "CPU host-filtered GpuScan rows" in plan
            # Warm the pools and establish a successful expansion/result baseline.
            check("expansion_baseline", query, mixed=True)
            # Allow the asynchronous Service close to release query buffers.
            deadline = time.monotonic() + 30
            while sql("SELECT count(*) FROM pgstrom.gpu_service_status WHERE active_clients<>0 OR queued_commands<>0 OR active_commands<>0") != "0":
                assert time.monotonic() < deadline, "pre-injection workload did not drain"
                time.sleep(0.2)
            reserved = sql("SELECT max(shared_reserved_bytes) FROM pgstrom.gpu_service_status")
            injection_armed = True  # also disarm if dispatch only reaches some QEs
            sql("SELECT pgstrom.shared_gpu_budget_inject_oom_segments(0,-1)")
            failed = subprocess.run(command, input=settings + query, text=True,
                                    capture_output=True, timeout=150)
            (out / "expansion.err").write_text(failed.stderr)
            (out / "expansion.out").write_text(failed.stdout)
            assert failed.returncode != 0 and not failed.stdout.strip(), "injected expansion returned success/partial rows"
            assert "injected GpuPreAgg expansion failure after budget reservation" in failed.stderr, \
                "expansion hook not reached; this run is not expansion-failure evidence"
            sql("SELECT pgstrom.shared_gpu_budget_inject_oom_segments(0,0)")
            injection_armed = False
            deadline = time.monotonic() + 30
            while sql("SELECT max(shared_reserved_bytes) FROM pgstrom.gpu_service_status") != reserved:
                assert time.monotonic() < deadline, "expansion failure leaked reservation"
                time.sleep(0.2)
            check("expansion_recovery", query, mixed=True)
        deadline = time.monotonic() + 30
        while True:
            bad = sql("""SELECT count(*) FROM pgstrom.gpu_service_status
              WHERE NOT ready OR active_clients<>0 OR queued_commands<>0 OR active_commands<>0
                 OR shared_reserved_bytes>shared_budget_bytes""")
            if bad == "0":
                break
            assert time.monotonic() < deadline, "services did not drain"
            time.sleep(0.2)
    finally:
        if injection_armed:
            sql("SELECT pgstrom.shared_gpu_budget_inject_oom_segments(0,0)")
        sql(f"DROP SCHEMA IF EXISTS {schema} CASCADE;")
        print("Artifacts: " + str(out), flush=True)
    (out / "PASS").write_text("GPU acceptance passed for " + args.stage + "\n")


if __name__ == "__main__":
    main()
