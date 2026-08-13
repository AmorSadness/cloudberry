#!/usr/bin/env bash
set -euo pipefail

psql_bin=${PSQL:-psql}
database=${PGDATABASE:-postgres}
repeat_count=${PGSTROM_GPUPREAGG_HAVING_REPEAT:-3}
psql_cmd=("$psql_bin" -X -v ON_ERROR_STOP=1 -d "$database")
run_dir=$(mktemp -d /tmp/pgstrom-gpupreagg-having.XXXXXX)
trap 'rm -rf "$run_dir"' EXIT INT TERM

if [[ ! $repeat_count =~ ^[1-9][0-9]*$ ]]; then
    echo "PGSTROM_GPUPREAGG_HAVING_REPEAT must be a positive integer: $repeat_count" >&2
    exit 1
fi

for relation in pgstrom_mvp_colocated pgstrom_mvp_heap; do
    if [[ $("${psql_cmd[@]}" -Atqc \
        "SELECT to_regclass('$relation') IS NOT NULL;") != t ]]; then
        echo "$relation is missing; rerun cloudberry/demo/setup.sql" >&2
        exit 1
    fi
done
if [[ $("${psql_cmd[@]}" -Atqc "
    SELECT count(*) = 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='pgstrom_mvp_colocated'
      AND column_name='nullable_metric';") != t ]]; then
    echo "nullable_metric is missing; rerun cloudberry/demo/setup.sql" >&2
    exit 1
fi

primary_segment_count=$("${psql_cmd[@]}" -Atqc "
    SELECT count(*) FROM gp_segment_configuration
    WHERE role='p' AND preferred_role='p' AND status='u' AND content >= 0;")
if [[ ! $primary_segment_count =~ ^[0-9]+$ ]] || (( primary_segment_count < 2 )); then
    echo "GpuPreAgg HAVING requires at least two up preferred Primary segments" >&2
    exit 1
fi

feature_settings="
 SET optimizer=off;
 SET pg_strom.enabled=on;
 SET pg_strom.enable_gpuscan=on;
 SET pg_strom.enable_gpupreagg=on;
 SET pg_strom.enable_gpusort=off;
 SET pg_strom.enable_numeric_aggfuncs=off;
 SET pg_strom.enable_partitionwise_gpupreagg=off;
 SET pg_strom.cloudberry_enable_host_quals=off;
 SET pg_strom.cpu_fallback=off;
 SET enable_seqscan=off;
 SET gp_enable_multiphase_agg=off;
 SET pg_strom.gpu_setup_cost=0;
 SET pg_strom.gpu_tuple_cost=0;
 SET pg_strom.gpu_operator_cost=0;
 SET gp_motion_cost_per_row=1000000;
 SET cpu_tuple_cost=10;
 SET cpu_operator_cost=10;"

# Keep one normal-cost observation for planner diagnostics.  HAVING support is
# a correctness/placement milestone; it does not require every legal shape to
# beat native HashAggregate, especially for colocated groups with no Motion to
# eliminate.
normal_settings="
 SET optimizer=off;
 SET pg_strom.enabled=on;
 SET pg_strom.enable_gpuscan=on;
 SET pg_strom.enable_gpupreagg=on;
 SET pg_strom.enable_gpusort=off;
 SET pg_strom.enable_numeric_aggfuncs=off;
 SET pg_strom.enable_partitionwise_gpupreagg=off;
 SET pg_strom.cloudberry_enable_host_quals=off;
 SET pg_strom.cpu_fallback=off;"

colocated_query="
 SELECT dist_key, count(*), sum(id)
 FROM pgstrom_mvp_colocated WHERE id > 0
 GROUP BY dist_key
 HAVING (max(nullable_metric) IS NULL OR sum(nullable_metric) > 0)
    AND (dist_key % 2) = 0"
noncolocated_query="
 SELECT grp, count(*), sum(nullable_metric), min(nullable_metric), max(nullable_metric)
 FROM pgstrom_mvp_colocated WHERE id > 0
 GROUP BY grp
 HAVING sum(nullable_metric) > 0 OR sum(nullable_metric) IS NULL"
unknown_query="
 SELECT grp, count(*), sum(nullable_metric)
 FROM pgstrom_mvp_colocated WHERE id > 0
 GROUP BY grp
 HAVING sum(nullable_metric) > 0"
empty_is_null_query="
 SELECT count(*), sum(nullable_metric)
 FROM pgstrom_mvp_colocated WHERE id < 0
 HAVING sum(nullable_metric) IS NULL"
empty_unknown_query="
 SELECT count(*), sum(nullable_metric)
 FROM pgstrom_mvp_colocated WHERE id < 0
 HAVING sum(nullable_metric) > 0"

stable_having_plan() {
    local label=$1 settings=$2 query=$3 expect_motion=$4
    local iteration plan first= plan_file agg_line gpu_line between
    for ((iteration = 1; iteration <= repeat_count; iteration++)); do
        plan=$("${psql_cmd[@]}" -Atqc \
            "$settings EXPLAIN (VERBOSE, COSTS OFF) $query")
        plan_file="$run_dir/$label.$iteration.plan"
        printf '%s\n' "$plan" >"$plan_file"
        if [[ -z $first ]]; then
            first=$plan
        elif [[ $plan != "$first" ]]; then
            echo "$label plan changed between identical planning attempts" >&2
            diff -u "$run_dir/$label.1.plan" "$plan_file" >&2 || true
            exit 1
        fi
    done
    printf '\n[%s HAVING plan]\n%s\n' "$label" "$first"
    grep -q 'Custom Scan (GpuPreAgg)' <<<"$first" || {
        echo "$label did not produce GpuPreAgg" >&2
        echo "[$label PG-Strom planner diagnostics]" >&2
        "${psql_cmd[@]}" -Atqc \
            "$settings SET client_min_messages=debug1;
             EXPLAIN (VERBOSE, COSTS OFF) $query" >&2 || true
        exit 1
    }
    agg_line=$(grep -n 'Aggregate' "$run_dir/$label.1.plan" | head -1 | cut -d: -f1)
    gpu_line=$(grep -n 'Custom Scan (GpuPreAgg)' "$run_dir/$label.1.plan" | head -1 | cut -d: -f1)
    if [[ ! $agg_line =~ ^[0-9]+$ || ! $gpu_line =~ ^[0-9]+$ ]] ||
       (( agg_line >= gpu_line )); then
        echo "$label does not place a CPU final aggregate above GpuPreAgg" >&2
        exit 1
    fi
    between=$(sed -n "${agg_line},${gpu_line}p" "$run_dir/$label.1.plan")
    grep -q 'Filter:' <<<"$between" || {
        echo "$label HAVING filter is not attached to the CPU final aggregate" >&2
        exit 1
    }
    if [[ $expect_motion == no ]]; then
        ! grep -q 'Gather Motion' <<<"$between" || {
            echo "$label unexpectedly gathers before colocated HAVING final" >&2
            exit 1
        }
    else
        grep -q 'Gather Motion' <<<"$between" || {
            echo "$label must gather before non-colocated/global HAVING final" >&2
            exit 1
        }
    fi
}

compare_result_digest() {
    local label=$1 settings=$2 query=$3 cpu_digest gpu_digest
    cpu_digest=$("${psql_cmd[@]}" -AtF '|' -qc \
        "SET optimizer=off; SET pg_strom.enabled=off;
         SELECT * FROM ($query) AS q ORDER BY 1;" | sha256sum)
    gpu_digest=$("${psql_cmd[@]}" -AtF '|' -qc \
        "$settings SELECT * FROM ($query) AS q ORDER BY 1;" | sha256sum)
    [[ $cpu_digest == "$gpu_digest" ]] || {
        echo "$label CPU/GPU result digest mismatch" >&2
        exit 1
    }
    echo "$label: CPU/GPU result digest matched"
}

require_native() {
    local label=$1 query=$2 plan
    plan=$("${psql_cmd[@]}" -Atqc \
        "$normal_settings EXPLAIN (VERBOSE, COSTS OFF) $query")
    if grep -q 'Custom Scan (GpuPreAgg)' <<<"$plan"; then
        echo "$label unexpectedly produced GpuPreAgg" >&2
        exit 1
    fi
    echo "$label: safely retained native aggregate"
}

normal_plan=$("${psql_cmd[@]}" -Atqc \
    "$normal_settings EXPLAIN (VERBOSE, COSTS OFF) $colocated_query")
if grep -q 'Custom Scan (GpuPreAgg)' <<<"$normal_plan"; then
    echo "normal-cost colocated HAVING selected GpuPreAgg"
else
    echo "normal-cost colocated HAVING reasonably selected native CPU final aggregation"
fi

stable_having_plan colocated "$feature_settings" "$colocated_query" no
stable_having_plan noncolocated "$feature_settings" "$noncolocated_query" yes
stable_having_plan empty_is_null "$feature_settings" "$empty_is_null_query" yes
stable_having_plan empty_unknown "$feature_settings" "$empty_unknown_query" yes

compare_result_digest colocated "$feature_settings" "$colocated_query"
compare_result_digest noncolocated "$feature_settings" "$noncolocated_query"
compare_result_digest unknown "$feature_settings" "$unknown_query"
compare_result_digest empty_is_null "$feature_settings" "$empty_is_null_query"
compare_result_digest empty_unknown "$feature_settings" "$empty_unknown_query"

null_rows=$("${psql_cmd[@]}" -Atqc \
    "$feature_settings SELECT count(*) FROM ($empty_is_null_query) q;")
unknown_rows=$("${psql_cmd[@]}" -Atqc \
    "$feature_settings SELECT count(*) FROM ($empty_unknown_query) q;")
[[ $null_rows == 1 && $unknown_rows == 0 ]] || {
    echo "HAVING NULL three-valued result mismatch: is_null=$null_rows unknown=$unknown_rows" >&2
    exit 1
}
echo "empty aggregate HAVING NULL semantics: IS NULL kept 1 row, UNKNOWN kept 0 rows"

require_native "FILTER aggregate in HAVING" \
    "SELECT grp, count(*) FROM pgstrom_mvp_colocated WHERE id > 0
     GROUP BY grp HAVING count(*) FILTER (WHERE metric > 0) > 0"
require_native "DISTINCT aggregate in HAVING" \
    "SELECT grp, count(*) FROM pgstrom_mvp_colocated WHERE id > 0
     GROUP BY grp HAVING count(DISTINCT metric) > 0"
require_native "numeric aggregate in HAVING" \
    "SELECT grp, count(*) FROM pgstrom_mvp_heap WHERE id > 0
     GROUP BY grp HAVING sum(amount) > 0"

echo "Cloudberry GpuPreAgg HAVING acceptance passed"
