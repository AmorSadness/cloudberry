#!/usr/bin/env bash
set -euo pipefail

psql_bin=${PSQL:-psql}
database=${PGDATABASE:-postgres}
repeat_count=${PGSTROM_GPUPREAGG_REPEAT:-3}
psql_cmd=("$psql_bin" -X -v ON_ERROR_STOP=1 -d "$database")

if [[ ! $repeat_count =~ ^[1-9][0-9]*$ ]]; then
    echo "PGSTROM_GPUPREAGG_REPEAT must be a positive integer: $repeat_count" >&2
    exit 1
fi

primary_segment_count=$("${psql_cmd[@]}" -Atqc "
    SELECT count(DISTINCT content)
    FROM gp_segment_configuration
    WHERE role = 'p' AND preferred_role = 'p'
      AND status = 'u' AND content >= 0;")
if [[ ! $primary_segment_count =~ ^[0-9]+$ ]] ||
   (( primary_segment_count < 2 )); then
    echo "GpuPreAgg MVP requires at least two up preferred primaries; found $primary_segment_count" >&2
    exit 1
fi

for relation in pgstrom_mvp_heap pgstrom_mvp_skew pgstrom_mvp_small \
                pgstrom_mvp_ao pgstrom_mvp_aoco pgstrom_mvp_partitioned; do
    if [[ $("${psql_cmd[@]}" -Atqc "SELECT to_regclass('$relation') IS NOT NULL;") != t ]]; then
        echo "$relation is missing; run cloudberry/demo/run_demo.sh or setup.sql first" >&2
        exit 1
    fi
done

if [[ $("${psql_cmd[@]}" -Atqc "SHOW pg_strom.enable_gpupreagg;") != off ]]; then
    echo "pg_strom.enable_gpupreagg must be off by default" >&2
    exit 1
fi
if [[ $("${psql_cmd[@]}" -Atqc "SHOW pg_strom.enable_gpusort;") != off ]] ||
   [[ $("${psql_cmd[@]}" -Atqc "SHOW pg_strom.enable_numeric_aggfuncs;") != off ]] ||
   [[ $("${psql_cmd[@]}" -Atqc "SHOW pg_strom.enable_partitionwise_gpupreagg;") != off ]]; then
    echo "GpuSort, numeric aggregates, and partitionwise GpuPreAgg must remain off" >&2
    exit 1
fi

gpu_settings="
    SET optimizer=off;
    SET pg_strom.enabled=on;
    SET pg_strom.enable_gpuscan=on;
    SET pg_strom.enable_gpupreagg=on;
    SET pg_strom.enable_gpusort=off;
    SET pg_strom.enable_numeric_aggfuncs=off;
    SET pg_strom.enable_partitionwise_gpupreagg=off;
    SET pg_strom.cloudberry_enable_host_quals=off;
    SET pg_strom.cpu_fallback=off;
    -- Expose the legal GpuPreAgg path for correctness testing only.  Native
    -- Cloudberry partial aggregation can otherwise win before GpuPreAgg is
    -- considered, especially when Motion is expensive.  These settings are
    -- not benchmark settings and do not establish a performance win.
    SET gp_enable_multiphase_agg=off;
    SET pg_strom.gpu_setup_cost=0;
    SET pg_strom.gpu_tuple_cost=0;
    SET pg_strom.gpu_operator_cost=0;
    SET gp_motion_cost_per_row=1000000;
    SET cpu_tuple_cost=10;
    SET cpu_operator_cost=10;
    SET enable_seqscan=off;"

# The deliberately tiny one-nonempty-QE relation contains only 16 rows.  Its
# native aggregate can dominate GpuPreAgg even with the general acceptance
# costs above.  Penalize CPU work only for this plan/result check; this is still
# a correctness test, not a benchmark configuration.  M5a colocated placement
# has its own runner, so this historical Gather-only matrix groups by metric.
small_gpu_settings="
    SET cpu_tuple_cost=100000;
    SET cpu_operator_cost=100000;"

require_gpupreagg_plan() {
    local label=$1
    local query=$2
    local extra_settings=${3:-}
    local plan

    plan=$("${psql_cmd[@]}" -Atqc "
        $gpu_settings
        $extra_settings
        EXPLAIN (ANALYZE, VERBOSE, COSTS OFF) $query")
    printf '\n[%s GpuPreAgg plan]\n%s\n' "$label" "$plan"
    if ! grep -q 'Custom Scan (GpuPreAgg)' <<<"$plan"; then
        echo "$label did not produce GpuPreAgg" >&2
        exit 1
    fi
    if ! grep -Eq "Motion .*\\(slice[1-9][0-9]*; segments: ${primary_segment_count}\\)" <<<"$plan"; then
        echo "$label does not show GpuPreAgg partial rows below a $primary_segment_count-primary Motion" >&2
        exit 1
    fi
    if ! grep -Eq 'Aggregate|HashAggregate' <<<"$plan"; then
        echo "$label does not show a CPU final aggregate above Motion" >&2
        exit 1
    fi
    if ! grep -Eq 'GpuPreAgg Sizing.*local groups: [0-9]+.*per-device final buffer:' <<<"$plan"; then
        echo "$label does not expose the M4a local-group/final-buffer estimate" >&2
        exit 1
    fi
    if grep -q 'GPU-Sort' <<<"$plan"; then
        echo "$label unexpectedly enabled GPU-Sort" >&2
        exit 1
    fi
}

require_native_aggregate_plan() {
    local label=$1
    local query=$2
    local extra_settings=${3:-}
    local plan

    plan=$("${psql_cmd[@]}" -Atqc "
        $gpu_settings
        $extra_settings
        EXPLAIN (VERBOSE, COSTS OFF) $query")
    printf '\n[%s fallback plan]\n%s\n' "$label" "$plan"
    if grep -q 'Custom Scan (GpuPreAgg)' <<<"$plan"; then
        echo "$label unexpectedly produced GpuPreAgg" >&2
        exit 1
    fi
}

compare_result() {
    local label=$1
    local query=$2
    local extra_settings=${3:-}
    local cpu
    local gpu
    local iteration

    cpu=$("${psql_cmd[@]}" -AtF '|' -qc "
        SET optimizer=off;
        SET pg_strom.enabled=off;
        $query")
    for ((iteration = 1; iteration <= repeat_count; iteration++)); do
        gpu=$("${psql_cmd[@]}" -AtF '|' -qc "
            $gpu_settings
            $extra_settings
            $query")
        if [[ $cpu != "$gpu" ]]; then
            echo "$label CPU/GPU mismatch on iteration $iteration" >&2
            printf 'CPU:\n%s\nGPU:\n%s\n' "$cpu" "$gpu" >&2
            exit 1
        fi
        echo "$label GPU iteration $iteration/$repeat_count: result matched"
    done
}

uniform_query="
    SELECT grp, count(*), count(id), sum(id), min(id), max(id)
    FROM pgstrom_mvp_heap
    WHERE grp BETWEEN 101 AND 207 AND id > 0
    GROUP BY grp
    ORDER BY grp;"
global_query="
    SELECT count(*), count(id), sum(id), min(id), max(id)
    FROM pgstrom_mvp_heap
    WHERE grp BETWEEN 101 AND 207 AND id > 0;"
float_query="
    SELECT grp, sum(id::float8), min(id::float8), max(id::float8)
    FROM pgstrom_mvp_heap
    WHERE grp BETWEEN 101 AND 107 AND id > 0
    GROUP BY grp
    ORDER BY grp;"
skew_query="
    SELECT metric, count(*), count(nullable_metric),
           sum(id), min(nullable_metric), max(nullable_metric)
    FROM pgstrom_mvp_skew
    WHERE metric BETWEEN -25 AND 25 AND id > 0
    GROUP BY metric
    ORDER BY metric;"
small_query="
    SELECT metric, count(*), count(nullable_metric), sum(id), min(id), max(id)
    FROM pgstrom_mvp_small
    WHERE id BETWEEN 1 AND 16
    GROUP BY metric
    ORDER BY metric;"
empty_query="
    SELECT count(*), count(id), sum(id), min(id), max(id)
    FROM pgstrom_mvp_heap
    WHERE (id % 100000000) = -1;"

require_gpupreagg_plan "uniform cross-Segment groups" "$uniform_query"
require_gpupreagg_plan "global aggregate" "$global_query"
require_gpupreagg_plan "exact float8 aggregate" "$float_query"
require_gpupreagg_plan "single-Segment skew" "$skew_query"
require_gpupreagg_plan "one nonempty QE" "$small_query" "$small_gpu_settings"
require_gpupreagg_plan "all QEs empty" "$empty_query"

compare_result "uniform cross-Segment groups" "$uniform_query"
compare_result "global aggregate" "$global_query"
compare_result "exact float8 aggregate" "$float_query"
compare_result "single-Segment skew" "$skew_query"
compare_result "one nonempty QE" "$small_query" "$small_gpu_settings"
compare_result "all QEs empty" "$empty_query"

require_native_aggregate_plan "no device qual" \
    "SELECT grp, count(*) FROM pgstrom_mvp_heap GROUP BY grp;"
require_native_aggregate_plan "mixed host/device quals with P1 GUC off" \
    "SELECT grp, count(*) FROM pgstrom_mvp_heap
     WHERE id > 0 AND payload ~ '^[0-7]' GROUP BY grp;"
require_native_aggregate_plan "numeric aggregate" \
    "SELECT grp, sum(amount) FROM pgstrom_mvp_heap WHERE id > 0 GROUP BY grp;"
require_native_aggregate_plan "aggregate FILTER" \
    "SELECT grp, count(*) FILTER (WHERE id > 10)
     FROM pgstrom_mvp_heap WHERE id > 0 GROUP BY grp;"
require_native_aggregate_plan "unsupported aggregate FILTER in HAVING" \
    "SELECT grp, count(*) FROM pgstrom_mvp_heap
     WHERE id > 0 GROUP BY grp
     HAVING count(*) FILTER (WHERE id > 10) > 0;"
require_native_aggregate_plan "AO heap" \
    "SELECT grp, count(*) FROM pgstrom_mvp_ao WHERE id > 0 GROUP BY grp;"
require_native_aggregate_plan "AOCO heap" \
    "SELECT grp, count(*) FROM pgstrom_mvp_aoco WHERE id > 0 GROUP BY grp;"
require_native_aggregate_plan "partitioned heap" \
    "SELECT grp, count(*) FROM pgstrom_mvp_partitioned WHERE id > 0 GROUP BY grp;"
require_native_aggregate_plan "ORCA" \
    "SELECT grp, count(*) FROM pgstrom_mvp_heap WHERE id > 0 GROUP BY grp;" \
    "SET optimizer=on;"

echo "Cloudberry Gather-only GpuPreAgg MVP acceptance passed"
