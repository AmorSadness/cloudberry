#!/usr/bin/env bash
set -euo pipefail

psql_bin=${PSQL:-psql}
database=${PGDATABASE:-postgres}
demo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

psql_cmd=("$psql_bin" -X -v ON_ERROR_STOP=1 -d "$database")
"${psql_cmd[@]}" -f "$demo_dir/setup.sql"

plan=$("${psql_cmd[@]}" -Atqc "
    SET optimizer=off;
    SET pg_strom.enabled=on;
    SET pg_strom.enable_gpuscan=on;
    SET enable_seqscan=off;
    EXPLAIN (ANALYZE, VERBOSE, COSTS OFF)
      SELECT id FROM pgstrom_mvp_heap
      WHERE grp BETWEEN 101 AND 207 AND amount >= 500.00;")
printf '%s\n' "$plan"
grep -q 'Custom Scan (GpuScan)' <<<"$plan"
if ! grep -Eq 'Motion .*\(slice[1-9][0-9]*; segments: 1\)' <<<"$plan"; then
    echo 'GpuScan plan does not show a single-primary QE slice below Motion' >&2
    exit 1
fi

signature_sql="
    SELECT count(*) || '|' || coalesce(sum(id)::text,'') || '|' ||
           coalesce(sum(amount)::text,'') || '|' ||
           md5(string_agg(id::text || ':' || payload, ',' ORDER BY id))
    FROM pgstrom_mvp_heap
    WHERE grp BETWEEN 101 AND 207 AND amount >= 500.00;"
cpu=$("${psql_cmd[@]}" -Atqc "SET optimizer=off; SET pg_strom.enabled=off; $signature_sql")
gpu=$("${psql_cmd[@]}" -Atqc "SET optimizer=off; SET pg_strom.enabled=on;
                               SET enable_seqscan=off; $signature_sql")
if [[ $cpu != "$gpu" ]]; then
    echo "CPU/GPU signature mismatch: CPU=$cpu GPU=$gpu" >&2
    exit 1
fi

"${psql_cmd[@]}" -f "$demo_dir/verify.sql"

unsupported_plan=$("${psql_cmd[@]}" -Atqc "
    SET optimizer=on;
    EXPLAIN SELECT * FROM pgstrom_mvp_heap WHERE grp=42;")
if grep -q 'GpuScan' <<<"$unsupported_plan"; then
    echo 'ORCA unexpectedly produced a GpuScan' >&2
    exit 1
fi

for fallback_case in \
    "SELECT * FROM pgstrom_mvp_ao WHERE grp=42" \
    "SELECT * FROM pgstrom_mvp_aoco WHERE grp=42" \
    "SELECT * FROM pgstrom_mvp_partitioned WHERE grp=42" \
    "SELECT * FROM pgstrom_mvp_heap WHERE payload ~ '^[0-9a-f]{8}'"
do
    fallback_plan=$("${psql_cmd[@]}" -Atqc "
        SET optimizer=off;
        SET pg_strom.enabled=on;
        SET enable_seqscan=off;
        EXPLAIN $fallback_case;")
    if grep -q 'GpuScan' <<<"$fallback_plan"; then
        echo "unsupported case unexpectedly produced a GpuScan: $fallback_case" >&2
        exit 1
    fi
done

echo "GpuScan plan found and CPU/GPU signatures match: $gpu"
echo 'The verbose plan shows GpuScan in a single-primary QE slice.'
