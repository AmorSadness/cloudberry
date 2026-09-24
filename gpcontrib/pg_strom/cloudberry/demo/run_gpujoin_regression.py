#!/usr/bin/env python3
"""Manual Cloudberry colocated GpuJoin GPU acceptance (psql + Python stdlib)."""
import argparse
from concurrent.futures import ThreadPoolExecutor
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


def verify_plan(plan, positive):
    joins = [n for n in nodes(plan) if n.get("Custom Plan Provider") == "GpuJoin"]
    if not positive:
        if joins:
            raise AssertionError("unsupported case acquired a GpuJoin")
        return
    if len(joins) != 1:
        raise AssertionError("positive case requires exactly one GpuJoin")
    join = joins[0]
    if join.get("Cloudberry Join") != "Colocated INNER hash join":
        raise AssertionError("colocated join diagnostic missing")
    children = list(nodes(join))[1:]
    if any("Motion" in n.get("Node Type", "") for n in children):
        raise AssertionError("Motion underneath GpuJoin")
    if not any(n.get("Node Type") == "Seq Scan" for n in children):
        raise AssertionError("native inner Seq Scan missing")
    if any(n.get("Custom Plan Provider") for n in children):
        raise AssertionError("unexpected custom inner path")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--normal-planner", action="store_true")
    parser.add_argument("--clients", type=int, default=4)
    parser.add_argument("--fault-injection", action="store_true",
                        help="superuser, otherwise idle dedicated cluster: post-reservation failure")
    args = parser.parse_args()
    if not 1 <= args.clients <= 64:
        parser.error("--clients must be 1..64")
    out = Path(os.environ.get("PGSTROM_RESULTS", f"/tmp/pgstrom-gpujoin-{uuid.uuid4().hex}"))
    out.mkdir(parents=True, exist_ok=False)
    schema = "pgstrom_join_" + uuid.uuid4().hex
    command = [os.environ.get("PSQL", "psql"), "-X", "-qAt", "-v", "ON_ERROR_STOP=1",
               "-d", os.environ.get("PGDATABASE", "postgres")]
    settings = f"""
      SET search_path={schema},public; SET optimizer=off;
      SET statement_timeout='120s'; SET max_parallel_workers_per_gather=0;
      SET pg_strom.enabled=on; SET pg_strom.enable_gpujoin=on;
      SET pg_strom.enable_gpuhashjoin=on; SET pg_strom.enable_gpupreagg=off;
      SET pg_strom.enable_gpuscan=off; SET pg_strom.cpu_fallback=off;
      SET pg_strom.cloudberry_gpujoin_max_inner_size='256MB';
    """
    if not args.normal_planner:
        settings += """
          SET enable_hashjoin=off; SET enable_mergejoin=off; SET enable_nestloop=off;
          SET pg_strom.gpu_setup_cost=0; SET pg_strom.gpu_tuple_cost=0;
          SET pg_strom.gpu_operator_cost=0;
        """
    cpu_settings = f"SET search_path={schema},public; SET optimizer=off; SET pg_strom.enabled=off; SET statement_timeout='120s';"
    armed = False
    created = False

    def sql(query, prefix="", allow_error=False):
        result = subprocess.run(command, input=prefix + query, text=True,
                                capture_output=True, timeout=150)
        if allow_error:
            return result
        if result.returncode:
            raise RuntimeError(result.stderr + "\nSQL: " + query)
        return result.stdout.strip()

    def save(label, data):
        (out / label).write_text(data + "\n")

    def ordered(query):
        # Full sorted multiset, preserving duplicates and NULLs (no DISTINCT).
        return "SELECT row_to_json(q)::text FROM (" + query + ") q ORDER BY 1"

    def check(label, query, positive=True, extra=""):
        query = ordered(query)
        raw = sql("EXPLAIN (ANALYZE, VERBOSE, FORMAT JSON) " + query, settings + extra)
        save(label + ".plan.json", raw)
        verify_plan(json.loads(raw)[0]["Plan"], positive)
        cpu = sql(query, cpu_settings)
        save(label + ".cpu", cpu)
        for repeat in range(3):
            actual = sql(query, settings + extra)
            save(f"{label}.{repeat}.gpu", actual)
            if actual != cpu:
                raise AssertionError(label + ": CPU/GPU multiset mismatch")
        print(label + ": PASS", flush=True)
        return cpu

    def drain():
        deadline = time.monotonic() + 60
        while True:
            if sql("""SELECT count(*) FROM pgstrom.gpu_service_status
                WHERE NOT ready OR active_clients<>0 OR queued_commands<>0 OR active_commands<>0""") == "0":
                return
            if time.monotonic() >= deadline:
                raise AssertionError("GPU Services did not drain")
            time.sleep(0.5)

    try:
        root = Path(__file__).resolve().parents[4]
        rev = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, text=True,
                             capture_output=True, check=True).stdout
        diff = subprocess.run(["git", "diff", "--binary", "--", "gpcontrib/pg_strom"],
                              cwd=root, text=True, capture_output=True, check=True).stdout
        save("revision.txt", rev)
        save("changes.patch", diff)
        # Include untracked source/test files in provenance as well.
        import hashlib
        base = Path(__file__).resolve().parents[2]
        hashes = []
        for folder in (base / "src", base / "cloudberry"):
            for file in sorted(folder.rglob("*")):
                if file.is_file() and file.suffix in (".c", ".h", ".cu", ".py", ".sh", ".sql"):
                    hashes.append(hashlib.sha256(file.read_bytes()).hexdigest() + " " + str(file.relative_to(base)))
        save("source-sha256.txt", "\n".join(hashes))
        deadline = time.monotonic() + 120
        while sql("""SELECT count(DISTINCT content_id)>=3 AND
            bool_and(ready AND actual_workers=configured_workers) FROM pgstrom.gpu_service_status""") != "t":
            if time.monotonic() >= deadline:
                raise RuntimeError("QD and at least two Primary GPU Services must be ready")
            time.sleep(1)
        save("metadata.txt", sql("""SELECT version();
            SELECT extversion FROM pg_extension WHERE extname='pg_strom';
            SELECT row_to_json(s) FROM pgstrom.gpu_service_status s;
            SHOW pg_strom.enable_gpujoin;"""))
        sql(f"CREATE SCHEMA {schema}")
        created = True
        sql("""
          CREATE TABLE a(k int, j int, v int) DISTRIBUTED BY(k);
          CREATE TABLE b(k int, j int, v int) DISTRIBUTED BY(k);
          INSERT INTO a SELECT CASE WHEN g%97=0 THEN NULL ELSE g%1024 END,g%7,g FROM generate_series(1,12000) g;
          INSERT INTO b SELECT CASE WHEN g%89=0 THEN NULL ELSE g%1024 END,g%7,g FROM generate_series(1,2000) g;
          INSERT INTO a VALUES (7,1,7),(7,1,7),(NULL,1,1);
          INSERT INTO b VALUES (7,1,7),(7,1,7),(7,1,7),(NULL,1,1);
          CREATE TABLE c(k int,j int,v int) DISTRIBUTED BY(k,j);
          CREATE TABLE d(k int,j int,v int) DISTRIBUTED BY(k,j);
          INSERT INTO c SELECT * FROM a; INSERT INTO d SELECT * FROM b;
          CREATE TABLE reversed(k int,j int,v int) DISTRIBUTED BY(j,k);
          INSERT INTO reversed SELECT * FROM b;
          CREATE TABLE random_t(k int,j int,v int) DISTRIBUTED RANDOMLY;
          CREATE TABLE repl(k int,j int,v int) DISTRIBUTED REPLICATED;
          INSERT INTO random_t SELECT * FROM b; INSERT INTO repl SELECT * FROM b;
          CREATE TABLE empty_t(k int,j int,v int) DISTRIBUTED BY(k);
          CREATE TABLE wide_key(k bigint,j int,v int) DISTRIBUTED BY(k);
          INSERT INTO wide_key SELECT * FROM b;
          CREATE TABLE part(k int,j int,v int) DISTRIBUTED BY(k) PARTITION BY RANGE(v)
            (START(0) END(20000) EVERY(10000));
          INSERT INTO part SELECT * FROM b;
          CREATE TABLE ao(k int,j int,v int) WITH(appendoptimized=true) DISTRIBUTED BY(k);
          INSERT INTO ao SELECT * FROM b;
          CREATE FUNCTION host_only(int) RETURNS boolean LANGUAGE plpgsql STABLE AS
            $$BEGIN RETURN $1 % 2 = 0; END$$;
          ANALYZE a; ANALYZE b; ANALYZE c; ANALYZE d; ANALYZE reversed;
          ANALYZE random_t; ANALYZE repl; ANALYZE empty_t; ANALYZE wide_key; ANALYZE part; ANALYZE ao;
        """, cpu_settings)
        simple = "SELECT a.k,a.v AS av,b.v AS bv FROM a JOIN b ON a.k=b.k"
        expected = check("duplicates_null_unfiltered", simple)
        check("reversed_clause", "SELECT a.k,a.v,b.v AS bv FROM a JOIN b ON b.k=a.k WHERE a.v>100 AND b.v<1000")
        check("composite", "SELECT c.k,c.j,c.v,d.v AS dv FROM c JOIN d ON c.k=d.k AND c.j=d.j")
        check("extra_join_qual", "SELECT a.v,b.v AS bv FROM a JOIN b ON a.k=b.k AND a.v>b.v")
        check("project_away_keys", "SELECT a.v,b.v AS bv FROM a JOIN b ON a.k=b.k")
        check("empty_inner", "SELECT a.v,e.v AS ev FROM a JOIN empty_t e ON a.k=e.k")
        check("empty_outer", "SELECT e.v,a.v AS av FROM empty_t e JOIN a ON e.k=a.k")
        check("self_join", "SELECT a.k,a.v,b.v AS bv FROM b a JOIN b ON a.k=b.k")
        for typ in ("smallint", "bigint"):
            sql(f"CREATE TABLE t1_{typ}(k {typ},v int) DISTRIBUTED BY(k); "
                f"CREATE TABLE t2_{typ}(k {typ},v int) DISTRIBUTED BY(k); "
                f"INSERT INTO t1_{typ} SELECT k,v FROM a; INSERT INTO t2_{typ} SELECT k,v FROM b; "
                f"ANALYZE t1_{typ}; ANALYZE t2_{typ};", cpu_settings)
            check(typ, f"SELECT x.k,x.v,y.v AS yv FROM t1_{typ} x JOIN t2_{typ} y ON x.k=y.k")
        negatives = {
            "partial_composite": "SELECT c.v,d.v AS dv FROM c JOIN d ON c.k=d.k",
            "policy_order": "SELECT c.v,r.v AS rv FROM c JOIN reversed r ON c.k=r.k AND c.j=r.j",
            "different_key_count": "SELECT a.v,c.v AS cv FROM a JOIN c ON a.k=c.k",
            "expression_key": "SELECT a.v,b.v AS bv FROM a JOIN b ON a.k+0=b.k",
            "cross_type": "SELECT a.v,b.v AS bv FROM a JOIN wide_key b ON a.k=b.k",
            "non_distribution_key": "SELECT a.v,b.v AS bv FROM a JOIN b ON a.v=b.v",
            "null_safe": "SELECT a.v,b.v AS bv FROM a JOIN b ON a.k IS NOT DISTINCT FROM b.k",
            "left": "SELECT a.v,b.v AS bv FROM a LEFT JOIN b ON a.k=b.k",
            "full": "SELECT a.v,b.v AS bv FROM a FULL JOIN b ON a.k=b.k",
            "semi": "SELECT a.v FROM a WHERE EXISTS(SELECT 1 FROM b WHERE a.k=b.k)",
            "anti": "SELECT a.v FROM a WHERE NOT EXISTS(SELECT 1 FROM b WHERE a.k=b.k)",
            "random": "SELECT a.v,b.v AS bv FROM a JOIN random_t b ON a.k=b.k",
            "replicated": "SELECT a.v,b.v AS bv FROM a JOIN repl b ON a.k=b.k",
            "partition": "SELECT a.v,b.v AS bv FROM a JOIN part b ON a.k=b.k",
            "ao": "SELECT a.v,b.v AS bv FROM a JOIN ao b ON a.k=b.k",
            "host_where": "SELECT a.v,b.v AS bv FROM a JOIN b ON a.k=b.k WHERE host_only(a.v)",
            "three_tables": "SELECT a.v,b.v AS bv,e.v AS ev FROM a JOIN b ON a.k=b.k JOIN b e ON b.k=e.k WHERE a.v<10",
            "known_empty": "SELECT a.v,b.v AS bv FROM a JOIN b ON a.k=b.k WHERE false",
        }
        # Native fallback tests use ordinary CPU join settings to avoid expensive
        # disabled-method nested loops; GpuJoin remains enabled and cheap.
        native_costs = "SET enable_hashjoin=on; SET enable_mergejoin=on; SET enable_nestloop=on;"
        for label, query in negatives.items():
            check(label, query, False, native_costs)
        check("disabled", simple, False, native_costs + "SET pg_strom.enable_gpujoin=off;")
        check("hash_disabled", simple, False, native_costs + "SET pg_strom.enable_gpuhashjoin=off;")
        check("orca", simple, False, native_costs + "SET optimizer=on;")
        # Same backend, forced generic plan, three executions (not three sessions).
        prepared = "PREPARE j(int) AS " + ordered(simple + " WHERE a.v>$1") + ";"
        raw = sql(prepared + "EXPLAIN (ANALYZE, VERBOSE, FORMAT JSON) EXECUTE j(100);",
                  settings + "SET plan_cache_mode=force_generic_plan;")
        save("prepared.plan.json", raw)
        verify_plan(json.loads(raw)[0]["Plan"], True)
        executions = "EXECUTE j(100); EXECUTE j(500); UPDATE b SET v=-v WHERE k=7; EXECUTE j(100); ROLLBACK;"
        actual = sql("BEGIN;" + prepared + executions, settings + "SET plan_cache_mode=force_generic_plan;")
        baseline = sql("BEGIN;" + prepared + executions, cpu_settings + "SET plan_cache_mode=force_generic_plan;")
        save("prepared.gpu", actual)
        save("prepared.cpu", baseline)
        if actual != baseline:
            raise AssertionError("generic prepared execution mismatch")
        # Cache a small positive plan, then enlarge both possible inner sides
        # without DDL invalidation. This tests the actual cap, not an estimate.
        sql("CREATE TABLE lim_a(k int,v int) DISTRIBUTED BY(k); "
            "CREATE TABLE lim_b(k int,v int) DISTRIBUTED BY(k); "
            "INSERT INTO lim_a SELECT g,g FROM generate_series(1,100) g; "
            "INSERT INTO lim_b SELECT * FROM lim_a; ANALYZE lim_a; ANALYZE lim_b;", cpu_settings)
        limit_query = "SELECT a.v,b.v AS bv FROM lim_a a JOIN lim_b b ON a.k=b.k"
        limit_prefix = settings + "SET plan_cache_mode=force_generic_plan; SET pg_strom.cloudberry_gpujoin_max_inner_size='1MB';"
        limit_prepare = "PREPARE limited AS " + limit_query + ";"
        raw = sql(limit_prepare + "EXPLAIN (FORMAT JSON) EXECUTE limited;", limit_prefix)
        save("runtime_limit.plan.json", raw)
        verify_plan(json.loads(raw)[0]["Plan"], True)
        failure = sql(limit_prepare + "EXPLAIN (FORMAT JSON) EXECUTE limited; "
                      "INSERT INTO lim_a SELECT g,g FROM generate_series(101,120000) g; "
                      "INSERT INTO lim_b SELECT * FROM lim_a WHERE k>100; "
                      "SELECT 'LIMIT_EXECUTION_START'; EXECUTE limited;", limit_prefix, allow_error=True)
        save("runtime_limit.stderr", failure.stderr)
        save("runtime_limit.stdout", failure.stdout)
        if failure.returncode == 0 or "Cloudberry GpuJoin inner buffer exceeds cloudberry_gpujoin_max_inner_size" not in failure.stderr:
            raise AssertionError("runtime inner buffer limit was not exercised")
        # The plan was emitted in this same session before changing cardinality.
        before, marker, after = failure.stdout.partition("LIMIT_EXECUTION_START")
        if not marker or after.strip():
            raise AssertionError("runtime limit failed before execution or returned partial rows")
        verify_plan(json.loads(before)[0]["Plan"], True)
        check("after_runtime_limit", simple)
        drain()
        # Warm pools before recording idle accounting. Reservation comparison is
        # bounded: cached pool segments may remain, direct query buffers may not.
        save("before_concurrency.jsonl", sql("SELECT row_to_json(s) FROM pgstrom.gpu_service_status s"))
        with ThreadPoolExecutor(max_workers=args.clients) as pool:
            futures = [pool.submit(sql, ordered(simple), settings) for _ in range(args.clients)]
            for i, future in enumerate(futures):
                actual = future.result()
                save(f"concurrent.{i}.gpu", actual)
                if actual != expected:
                    raise AssertionError("concurrent join mismatch")
        drain()
        save("after_concurrency.jsonl", sql("SELECT row_to_json(s) FROM pgstrom.gpu_service_status s"))
        if args.fault_injection:
            # This direct query's first direct buffer is the join inner buffer.
            baseline_reserved = sql("SELECT content_id,gpu_id,local_reserved_bytes FROM pgstrom.gpu_service_status ORDER BY 1,2")
            armed = True
            sql("SELECT * FROM pgstrom.shared_gpu_budget_inject_oom_segments(0,1)")
            failure = sql(ordered(simple), settings, allow_error=True)
            save("allocation_failure.stderr", failure.stderr)
            save("allocation_failure.stdout", failure.stdout)
            if failure.returncode == 0 or "injected query-buffer allocation failure after budget reservation" not in failure.stderr:
                raise AssertionError("exact post-reservation injection not observed")
            if failure.stdout.strip():
                raise AssertionError("partial rows returned on allocation failure")
            sql("SELECT * FROM pgstrom.shared_gpu_budget_inject_oom_segments(0,0)")
            armed = False
            drain()
            deadline = time.monotonic() + 60
            while sql("SELECT content_id,gpu_id,local_reserved_bytes FROM pgstrom.gpu_service_status ORDER BY 1,2") != baseline_reserved:
                if time.monotonic() >= deadline:
                    raise AssertionError("allocation failure reservation did not return to baseline")
                time.sleep(0.5)
            check("after_injected_failure", simple)
        else:
            save("allocation_failure.SKIPPED", "Requires --fault-injection on an idle dedicated cluster")
        save("recovery.SKIPPED", "Cancel, SIGHUP, SIGKILL, pressure and actual rescan: follow design acceptance matrix")
        save("SELECTED_CASES_PASSED", "Selected cases passed; inspect *.SKIPPED. No performance or full acceptance claim.")
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
