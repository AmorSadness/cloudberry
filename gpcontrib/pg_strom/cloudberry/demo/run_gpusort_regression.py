#!/usr/bin/env python3
"""Manual GPU acceptance: ordered output, merge Motion and bounded GpuSort buffers."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid


def nodes(plan):
    yield plan
    for child in plan.get("Plans", []):
        yield from nodes(child)


def verify_plan(plan, positive=True, join=False, limited=False):
    all_nodes = list(nodes(plan))
    gpu = [n for n in all_nodes if "GPU-Sort keys" in n]
    if not positive:
        if gpu:
            raise AssertionError("unsupported case acquired GPU-Sort")
        return
    if len(gpu) != 1:
        raise AssertionError("positive case requires exactly one fused GPU-Sort")
    if gpu[0].get("Custom Plan Provider") != ("GpuJoin" if join else "GpuScan"):
        raise AssertionError("wrong GPU-Sort input provider")
    if "Cloudberry GPU-Sort" not in gpu[0]:
        raise AssertionError("Cloudberry sorting diagnostic absent")
    if any(n.get("Node Type") in ("Sort", "Incremental Sort") for n in all_nodes):
        raise AssertionError("CPU Sort would mask a missing GPU order contract")
    if not any("Motion" in n.get("Node Type", "") and n.get("Merge Key") and
               any(c is gpu[0] for c in nodes(n)) for n in all_nodes):
        raise AssertionError("global order requires merge-receive Motion above GPU-Sort")
    if any("Motion" in n.get("Node Type", "") for n in list(nodes(gpu[0]))[1:]):
        raise AssertionError("unexpected Motion inside fused input")
    if "GPU-Sort Limit" in gpu[0]:
        raise AssertionError("this milestone must not push down GPU Top-K")
    if limited and not any(n.get("Node Type") == "Limit" for n in all_nodes):
        raise AssertionError("native LIMIT absent")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--normal-planner", action="store_true")
    parser.add_argument("--clients", type=int, default=4)
    parser.add_argument("--buffer-limit", action="store_true", help="large fixture; cached-plan live-buffer cap failure")
    parser.add_argument("--fault-injection", action="store_true", help="superuser on an idle dedicated cluster")
    args = parser.parse_args()
    if not 1 <= args.clients <= 64:
        parser.error("--clients must be 1..64")
    out = Path(os.environ.get("PGSTROM_RESULTS", f"/tmp/pgstrom-gpusort-{uuid.uuid4().hex}"))
    out.mkdir(parents=True, exist_ok=False)
    schema = "pgstrom_sort_" + uuid.uuid4().hex
    command = [os.environ.get("PSQL", "psql"), "-X", "-qAt", "-v", "ON_ERROR_STOP=1",
               "-d", os.environ.get("PGDATABASE", "postgres")]
    common = f"SET search_path={schema},public; SET optimizer=off; SET statement_timeout='180s'; SET timezone='UTC';"
    settings = common + """
      SET pg_strom.enabled=on; SET pg_strom.enable_gpuscan=on;
      SET pg_strom.enable_gpujoin=on; SET pg_strom.enable_gpuhashjoin=on;
      SET pg_strom.enable_gpupreagg=off; SET pg_strom.enable_gpusort=on;
      SET pg_strom.cpu_fallback=off; SET max_parallel_workers_per_gather=0;
      SET pg_strom.cloudberry_gpusort_max_buffer_size='256MB';
    """
    cpu = common + "SET pg_strom.enabled=off;"
    if not args.normal_planner:
        settings += """
          SET enable_seqscan=off; SET enable_sort=off; SET enable_incremental_sort=off;
          SET enable_hashjoin=off; SET enable_mergejoin=off; SET enable_nestloop=off;
          SET pg_strom.gpu_setup_cost=0; SET pg_strom.gpu_tuple_cost=0; SET pg_strom.gpu_operator_cost=0;
        """
    native_costs = "SET enable_seqscan=on; SET enable_sort=on; SET enable_incremental_sort=on; SET enable_hashjoin=on; SET enable_mergejoin=on; SET enable_nestloop=on;"
    created = False
    armed = False

    def sql(query, prefix="", allow_error=False):
        result = subprocess.run(command, input=prefix + query, text=True,
                                capture_output=True, timeout=210)
        if allow_error:
            return result
        if result.returncode:
            raise RuntimeError(result.stderr + "\nSQL: " + query)
        return result.stdout.strip()

    def save(label, data):
        (out / label).write_text(data + "\n")

    def copy(query):
        # Preserve the SQL order. Never re-sort the output in SQL or Python.
        return "COPY (" + query + ") TO STDOUT WITH (FORMAT CSV, NULL '\\N');"

    def check(label, query, positive=True, extra="", join=False, limited=False):
        raw = sql("EXPLAIN (ANALYZE, VERBOSE, FORMAT JSON) " + query, settings + extra)
        save(label + ".plan.json", raw)
        verify_plan(json.loads(raw)[0]["Plan"], positive, join, limited)
        expected = sql(copy(query), cpu)
        save(label + ".cpu.csv", expected)
        for repeat in range(3):
            actual = sql(copy(query), settings + extra)
            save(f"{label}.{repeat}.gpu.csv", actual)
            if actual != expected:
                raise AssertionError(label + ": ordered CPU/GPU output mismatch")
        print(label + ": PASS", flush=True)
        return expected

    def drain():
        deadline = time.monotonic() + 60
        while sql("""SELECT count(*) FROM pgstrom.gpu_service_status
            WHERE NOT ready OR active_clients<>0 OR queued_commands<>0 OR active_commands<>0""") != "0":
            if time.monotonic() >= deadline:
                raise AssertionError("GPU Services did not drain")
            time.sleep(0.5)

    def reserved():
        return sql("SELECT content_id,gpu_id,local_reserved_bytes FROM pgstrom.gpu_service_status ORDER BY 1,2")

    try:
        base = Path(__file__).resolve().parents[2]
        root = base.parents[1]
        for label, gitargs in (("revision.txt", ["rev-parse", "HEAD"]),
                               ("changes.patch", ["diff", "--binary", "--", "gpcontrib/pg_strom", "src/backend/cdb/cdbplan.c"])):
            save(label, subprocess.run(["git", *gitargs], cwd=root, text=True,
                                       capture_output=True, check=True).stdout)
        files = [p for folder in (base / "src", base / "cloudberry") for p in folder.rglob("*")
                 if p.is_file() and p.suffix in (".c", ".cu", ".h", ".py", ".sh", ".sql")]
        files.append(root / "src/backend/cdb/cdbplan.c")
        save("source-sha256.txt", "\n".join(hashlib.sha256(p.read_bytes()).hexdigest() + " " + str(p.relative_to(root)) for p in sorted(files)))
        deadline = time.monotonic() + 120
        while sql("""SELECT count(DISTINCT content_id)>=3 AND count(DISTINCT gpu_id)=1
            AND bool_and(ready AND actual_workers=configured_workers) FROM pgstrom.gpu_service_status""") != "t":
            if time.monotonic() >= deadline:
                raise RuntimeError("requires QD + at least two ready Primaries, one GPU per Service")
            time.sleep(1)
        save("metadata.txt", sql("SELECT version(); SELECT extversion FROM pg_extension WHERE extname='pg_strom'; SELECT row_to_json(s) FROM pgstrom.gpu_service_status s;"))
        sql(f"CREATE SCHEMA {schema};")
        created = True
        sql("""
          CREATE TABLE t(id int,k int,b bool,s smallint,n bigint,d date,tm time,ts timestamp,tz timestamptz,
                         f float8,txt text,num numeric) DISTRIBUTED BY(id);
          INSERT INTO t SELECT g,CASE WHEN g%17=0 THEN NULL ELSE 100-g%201 END,
            CASE WHEN g%19=0 THEN NULL ELSE g%2=0 END,(g%30000)::smallint,
            (g::bigint*1000000000),date '2000-01-01'+(g%101),
            time '12:00'+(g%100)*interval '1 second',timestamp '2000-01-01'+g*interval '1 second',
            timestamptz '2000-01-01 UTC'+g*interval '1 second',g::float8,g::text,g::numeric
            FROM generate_series(1,12000) g;
          INSERT INTO t VALUES (-1,-2147483648,false,-32768,-9223372036854775808,'-infinity','00:00','-infinity','-infinity','NaN','a',1),
            (-2,2147483647,true,32767,9223372036854775807,'infinity','24:00','infinity','infinity','Infinity','b',2),
            (-3,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'-Infinity','c',NULL);
          INSERT INTO t SELECT * FROM t WHERE id=7;
          CREATE TABLE u(id int,v int) DISTRIBUTED BY(id);
          INSERT INTO u SELECT g,g%37 FROM generate_series(1,12000) g;
          INSERT INTO u VALUES (7,7),(7,7);
          CREATE TABLE empty_t(id int,k int) DISTRIBUTED BY(id);
          CREATE TABLE one_t(id int,k int) DISTRIBUTED BY(id); INSERT INTO one_t VALUES(1,NULL);
          CREATE TABLE repl(id int,k int) DISTRIBUTED REPLICATED; INSERT INTO repl SELECT id,k FROM t;
          CREATE TABLE ao(id int,k int) WITH(appendoptimized=true) DISTRIBUTED BY(id); INSERT INTO ao SELECT id,k FROM t;
          CREATE TABLE part(id int,k int) DISTRIBUTED BY(id) PARTITION BY RANGE(id)
            (START(-100) END(20000) EVERY(10050)); INSERT INTO part SELECT id,k FROM t;
          CREATE FUNCTION host_only(int) RETURNS boolean LANGUAGE plpgsql STABLE AS $$BEGIN RETURN $1%2=0; END$$;
          ANALYZE t; ANALYZE u; ANALYZE empty_t; ANALYZE one_t; ANALYZE repl; ANALYZE ao; ANALYZE part;
        """, cpu)
        simple = "SELECT id,k FROM t ORDER BY k ASC NULLS LAST,id"
        expected = check("unfiltered", simple)
        check("desc_nulls_first", "SELECT id,k FROM t ORDER BY k DESC NULLS FIRST,id DESC")
        check("asc_nulls_first", "SELECT id,k FROM t ORDER BY k ASC NULLS FIRST,id")
        check("desc_nulls_last", "SELECT id,k FROM t ORDER BY k DESC NULLS LAST,id")
        check("device_where", "SELECT id,k FROM t WHERE id>100 AND k<20 ORDER BY k DESC,id")
        check("hidden_key", "SELECT id FROM t ORDER BY k NULLS FIRST,id")
        check("multi_key", "SELECT id,k,b,n FROM t ORDER BY b DESC NULLS LAST,k NULLS FIRST,n DESC,id")
        for typ in ("b", "s", "n", "d", "tm", "ts", "tz"):
            check("type_" + typ, f"SELECT id,{typ} FROM t ORDER BY {typ} DESC NULLS FIRST,id")
        check("empty", "SELECT id,k FROM empty_t ORDER BY k,id")
        check("one", "SELECT id,k FROM one_t ORDER BY k,id")
        check("limit_offset", simple + " LIMIT 43 OFFSET 27", limited=True)
        check("ties", "SELECT k FROM t ORDER BY k NULLS LAST FETCH FIRST 7 ROWS WITH TIES", limited=True)
        join_query = "SELECT t.id,t.k,u.v FROM t JOIN u ON t.id=u.id ORDER BY t.k NULLS FIRST,t.id,u.v"
        check("join_sort", join_query, join=True)
        negatives = {
            "float_nan": "SELECT id,f FROM t ORDER BY f,id",
            "numeric": "SELECT id,num FROM t ORDER BY num,id",
            "collation": 'SELECT id,txt FROM t ORDER BY txt COLLATE "C",id',
            "expression": "SELECT id,k FROM t ORDER BY abs(k::bigint),id",
            "wide_payload": "SELECT id,txt FROM t ORDER BY id",
            "window": "SELECT id,row_number() OVER(ORDER BY id) AS rn FROM t ORDER BY id",
            "aggregate": "SELECT k,count(*) FROM t GROUP BY k ORDER BY k",
            "distinct": "SELECT DISTINCT k FROM t ORDER BY k",
            "host_where": "SELECT id,k FROM t WHERE host_only(id) ORDER BY k,id",
            "replicated": "SELECT id,k FROM repl ORDER BY k,id",
            "ao": "SELECT id,k FROM ao ORDER BY k,id",
            "partition": "SELECT id,k FROM part ORDER BY k,id",
        }
        for label, query in negatives.items():
            check(label, query, False, native_costs)
        check("disabled", simple, False, native_costs + "SET pg_strom.enable_gpusort=off;")
        check("fallback_enabled", simple, False, native_costs + "SET pg_strom.cpu_fallback=on;")
        check("orca", simple, False, native_costs + "SET optimizer=on;")
        # Generic plan reused within one backend, including changed data. psql
        # unaligned output is identical for these integer-only projections.
        prepared = "PREPARE sorted(int) AS SELECT id,k FROM t WHERE id>$1 ORDER BY k NULLS FIRST,id;"
        raw = sql(prepared + "EXPLAIN (ANALYZE,VERBOSE,FORMAT JSON) EXECUTE sorted(100);",
                  settings + "SET plan_cache_mode=force_generic_plan;")
        save("prepared.plan.json", raw)
        verify_plan(json.loads(raw)[0]["Plan"])
        batch = "BEGIN;" + prepared + "EXECUTE sorted(100); EXECUTE sorted(500); UPDATE t SET k=-123 WHERE id=777; EXECUTE sorted(100); ROLLBACK;"
        baseline = sql(batch, cpu + "SET plan_cache_mode=force_generic_plan;")
        actual = sql(batch, settings + "SET plan_cache_mode=force_generic_plan;")
        save("prepared.cpu", baseline)
        save("prepared.gpu", actual)
        if baseline != actual:
            raise AssertionError("prepared ordered output mismatch")
        drain()
        save("before_concurrency.jsonl", sql("SELECT row_to_json(s) FROM pgstrom.gpu_service_status s"))
        with ThreadPoolExecutor(max_workers=args.clients) as pool:
            futures = [pool.submit(sql, copy(simple), settings) for _ in range(args.clients)]
            for i, future in enumerate(futures):
                actual = future.result()
                save(f"concurrent.{i}.csv", actual)
                if actual != expected:
                    raise AssertionError("concurrent sorted result mismatch")
        drain()
        save("after_concurrency.jsonl", sql("SELECT row_to_json(s) FROM pgstrom.gpu_service_status s"))
        if args.buffer_limit:
            # Low-row cached plan + later INSERT avoids letting a planner
            # fallback masquerade as a runtime limit test.
            cols = ",".join(f"v{i} bigint" for i in range(8))
            values = ",".join("g::bigint" for _ in range(8))
            sql(f"CREATE TABLE big(id int,{cols}) DISTRIBUTED BY(id); INSERT INTO big SELECT g,{values} FROM generate_series(1,100) g; ANALYZE big;", cpu)
            prepare = "PREPARE bigsort AS SELECT * FROM big ORDER BY id;"
            fail = sql(prepare + "EXPLAIN (FORMAT JSON) EXECUTE bigsort; "
                       f"INSERT INTO big SELECT g,{values} FROM generate_series(101,1000000) g; "
                       "SELECT 'SORT_LIMIT_START'; EXECUTE bigsort;",
                       settings + "SET plan_cache_mode=force_generic_plan; SET pg_strom.cloudberry_gpusort_max_buffer_size='64MB';",
                       allow_error=True)
            save("buffer_limit.stdout", fail.stdout)
            save("buffer_limit.stderr", fail.stderr)
            before, marker, after = fail.stdout.partition("SORT_LIMIT_START")
            if not marker:
                raise AssertionError("runtime cap case did not reach EXECUTE")
            verify_plan(json.loads(before)[0]["Plan"])
            if fail.returncode == 0 or "Cloudberry GpuSort exceeds cloudberry_gpusort_max_buffer_size" not in fail.stderr or after.strip():
                raise AssertionError("expected precise buffer cap failure with no partial output")
            drain()
            check("after_buffer_limit", simple)
        else:
            save("buffer_limit.SKIPPED", "Use --buffer-limit for the million-row cached-plan allocation cap gate")
        if args.fault_injection:
            drain()
            baseline_reserved = reserved()
            armed = True
            sql("SELECT * FROM pgstrom.shared_gpu_budget_inject_oom_segments(0,1)")
            fail = sql(copy(simple), settings, allow_error=True)
            save("injection.stderr", fail.stderr)
            save("injection.stdout", fail.stdout)
            if fail.returncode == 0 or "injected query-buffer allocation failure after budget reservation" not in fail.stderr or fail.stdout.strip():
                raise AssertionError("expected initial projection allocation injection without partial output")
            sql("SELECT * FROM pgstrom.shared_gpu_budget_inject_oom_segments(0,0)")
            armed = False
            drain()
            deadline = time.monotonic() + 60
            while reserved() != baseline_reserved:
                if time.monotonic() >= deadline:
                    raise AssertionError("injection leaked reservations")
                time.sleep(0.5)
            check("after_injection", simple)
        else:
            save("allocation_failure.SKIPPED", "Use --fault-injection on an idle dedicated cluster")
        save("recovery.SKIPPED", "Cancel/disconnect, Service SIGHUP/SIGKILL, FIFO pressure, actual rescan and mixed workload gates remain manual")
        save("SELECTED_CASES_PASSED", "Selected cases passed. Inspect *.SKIPPED; no complete GPU acceptance/performance claim.")
    finally:
        try:
            if armed:
                sql("SELECT * FROM pgstrom.shared_gpu_budget_inject_oom_segments(0,0)")
            if created:
                sql(f"DROP SCHEMA {schema} CASCADE")
        finally:
            print("Artifacts: " + str(out), flush=True)


if __name__ == "__main__":
    main()
