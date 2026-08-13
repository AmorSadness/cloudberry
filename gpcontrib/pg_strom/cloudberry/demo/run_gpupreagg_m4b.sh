#!/usr/bin/env bash
set -euo pipefail

psql_bin=${PSQL:-psql}
database=${PGDATABASE:-postgres}
repeat_count=${PGSTROM_GPUPREAGG_M4B_REPEAT:-3}
psql_cmd=("$psql_bin" -X -v ON_ERROR_STOP=1 -d "$database")
run_dir=$(mktemp -d /tmp/pgstrom-gpupreagg-m4b.XXXXXX)
trap 'rm -rf "$run_dir"' EXIT INT TERM

if [[ ! $repeat_count =~ ^[1-9][0-9]*$ ]]; then
    echo "PGSTROM_GPUPREAGG_M4B_REPEAT must be a positive integer: $repeat_count" >&2
    exit 1
fi

for relation in pgstrom_mvp_heap pgstrom_mvp_skew; do
    if [[ $("${psql_cmd[@]}" -Atqc "SELECT to_regclass('$relation') IS NOT NULL;") != t ]]; then
        echo "$relation is missing; run cloudberry/demo/setup.sql first" >&2
        exit 1
    fi
done
for column in grp_medium grp_high; do
    if [[ $("${psql_cmd[@]}" -Atqc "
        SELECT count(*) = 2
        FROM information_schema.columns
        WHERE table_schema = 'public' AND column_name = '$column'
          AND table_name IN ('pgstrom_mvp_heap','pgstrom_mvp_skew');") != t ]]; then
        echo "M4b statistics column $column is missing; rerun cloudberry/demo/setup.sql" >&2
        exit 1
    fi
done

# M4b deliberately changes only feature gates.  All planner cost, Motion,
# multiphase aggregation and scan-method GUCs remain at the cluster/session
# defaults so this runner measures ordinary Postgres-planner competition.
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

settings=$("${psql_cmd[@]}" -AtF '|' -qc "$normal_settings
 SELECT current_setting('gp_enable_multiphase_agg'),
        current_setting('pg_strom.gpu_setup_cost'),
        current_setting('pg_strom.gpu_tuple_cost'),
        current_setting('pg_strom.gpu_operator_cost'),
        current_setting('gp_motion_cost_per_row'),
        current_setting('cpu_tuple_cost'),
        current_setting('cpu_operator_cost'),
        current_setting('enable_seqscan');")
IFS='|' read -r multiphase gpu_setup gpu_tuple gpu_operator motion cpu_tuple cpu_operator seqscan <<<"$settings"
if [[ $multiphase != on || $seqscan != on ]]; then
    echo "M4b needs ordinary planner defaults: gp_enable_multiphase_agg=on and enable_seqscan=on" >&2
    exit 1
fi
for value in "$gpu_setup" "$gpu_tuple" "$gpu_operator" "$cpu_tuple" "$cpu_operator"; do
    awk -v value="$value" 'BEGIN { exit !(value > 0 && value < 100000) }' || {
        echo "M4b refuses zero or acceptance-only extreme planner costs: $settings" >&2
        exit 1
    }
done
awk -v value="$motion" 'BEGIN { exit !(value >= 0 && value < 100000) }' || {
    echo "M4b refuses an acceptance-only extreme Motion cost: $settings" >&2
    exit 1
}
echo "normal planner costs: $settings"

low_query="
 SELECT grp, count(*), sum(id), min(id), max(id)
 FROM pgstrom_mvp_heap WHERE id > 0
 GROUP BY grp ORDER BY grp;"
medium_query="
 SELECT grp_medium, count(*), sum(id), min(id), max(id)
 FROM pgstrom_mvp_heap WHERE id > 0
 GROUP BY grp_medium ORDER BY grp_medium;"
high_query="
 SELECT grp_high, count(*), sum(id), min(id), max(id)
 FROM pgstrom_mvp_heap WHERE id > 0
 GROUP BY grp_high ORDER BY grp_high;"
unsuitable_query="
 SELECT id, count(*), sum(id)
 FROM pgstrom_mvp_heap WHERE id > 0
 GROUP BY id;"
skew_low_query="
 SELECT metric, count(*), sum(id), min(id), max(id)
 FROM pgstrom_mvp_skew WHERE id > 0
 GROUP BY metric ORDER BY metric;"
skew_high_query="
 SELECT id, count(*), sum(id)
 FROM pgstrom_mvp_skew WHERE id > 0
 GROUP BY id;"
skew_medium_query="
 SELECT grp_medium, count(*), sum(id), min(id), max(id)
 FROM pgstrom_mvp_skew WHERE id > 0
 GROUP BY grp_medium ORDER BY grp_medium;"
skew_cardinality_high_query="
 SELECT grp_high, count(*), sum(id), min(id), max(id)
 FROM pgstrom_mvp_skew WHERE id > 0
 GROUP BY grp_high ORDER BY grp_high;"

stable_plan() {
    local label=$1 query=$2 expected=$3 iteration plan first=
    for ((iteration = 1; iteration <= repeat_count; iteration++)); do
        plan=$("${psql_cmd[@]}" -Atqc "$normal_settings EXPLAIN (VERBOSE) $query")
        printf '%s\n' "$plan" >"$run_dir/$label.$iteration.plan"
        if [[ -z $first ]]; then
            first=$plan
        elif [[ $plan != "$first" ]]; then
            echo "$label plan changed between identical planning attempts" >&2
            diff -u "$run_dir/$label.1.plan" "$run_dir/$label.$iteration.plan" >&2 || true
            exit 1
        fi
    done
    printf '\n[%s normal plan]\n%s\n' "$label" "$first"
    case $expected in
        gpu)
            grep -q 'Custom Scan (GpuPreAgg)' <<<"$first" || {
                echo "$label should select GpuPreAgg with normal costs" >&2
                exit 1
            }
            ;;
        native)
            if grep -q 'Custom Scan (GpuPreAgg)' <<<"$first"; then
                echo "$label should reject GpuPreAgg with normal costs" >&2
                exit 1
            fi
            ;;
    esac
}

stable_plan low_uniform "$low_query" gpu
stable_plan medium_uniform "$medium_query" gpu
stable_plan high_uniform "$high_query" gpu
stable_plan near_detail_uniform "$unsuitable_query" native
stable_plan low_skew "$skew_low_query" either
stable_plan medium_skew "$skew_medium_query" either
stable_plan high_skew "$skew_cardinality_high_query" either
stable_plan near_detail_skew "$skew_high_query" native

compare_result_digest() {
    local label=$1 query=$2 cpu_digest gpu_digest
    cpu_digest=$("${psql_cmd[@]}" -AtF '|' -qc \
        "SET optimizer=off; SET pg_strom.enabled=off; $query" | sha256sum)
    gpu_digest=$("${psql_cmd[@]}" -AtF '|' -qc \
        "$normal_settings $query" | sha256sum)
    if [[ $cpu_digest != "$gpu_digest" ]]; then
        echo "$label CPU/GPU result digest mismatch" >&2
        exit 1
    fi
    echo "$label: CPU/GPU result digest matched"
}

compare_result_digest low_uniform "$low_query"
compare_result_digest medium_uniform "$medium_query"
compare_result_digest high_uniform "$high_query"
compare_result_digest low_skew "$skew_low_query"
compare_result_digest medium_skew "$skew_medium_query"
compare_result_digest high_skew "$skew_cardinality_high_query"

analyze_plan() {
    local label=$1 query=$2 plan
    plan=$("${psql_cmd[@]}" -Atqc \
        "$normal_settings EXPLAIN (ANALYZE, VERBOSE, COSTS ON) $query")
    printf '\n[%s analyzed plan]\n%s\n' "$label" "$plan"
    printf '%s\n' "$plan" >"$run_dir/$label.analyze"
    grep -q 'Custom Scan (GpuPreAgg)' <<<"$plan" || {
        echo "$label lost GpuPreAgg during EXPLAIN ANALYZE" >&2
        exit 1
    }
    grep -Eq 'GpuPreAgg Cost:.*GPU setup: [0-9].*host-device DMA: [0-9].*partial aggregate: [0-9].*QE-QD Motion: native Path.*CPU final aggregate: native Path' <<<"$plan" || {
        echo "$label does not expose the five M4b cost components" >&2
        exit 1
    }
    grep -Eq 'GpuPreAgg Actual:.*groups actual/estimate: [0-9.]+x.*usage/estimate: [0-9.]+%' <<<"$plan" || {
        echo "$label does not expose estimate/actual sizing deviation" >&2
        exit 1
    }
}

analyze_plan low_uniform "$low_query"
analyze_plan high_uniform "$high_query"
if grep -q 'Custom Scan (GpuPreAgg)' "$run_dir/low_skew.1.plan"; then
    analyze_plan low_skew "$skew_low_query"
else
    echo "low_skew reasonably selected native aggregation on its single nonempty Segment"
fi

if ! grep -Eq 'GpuPreAgg Sizing:.*per-device final buffer: (16\.00|18\.00|20\.00|22\.00|24\.00|26\.00|28\.00|30\.00|32\.00)MB' \
      "$run_dir/low_uniform.analyze"; then
    echo "low-cardinality GpuPreAgg buffer is not clearly below 1GiB" >&2
    exit 1
fi

# Compare the rows crossing Gather Motion for raw detail and GPU partial rows.
# This is a diagnostic pair, not a plan-forcing cost setup.
detail_plan=$("${psql_cmd[@]}" -Atqc "$normal_settings
 SET pg_strom.enable_gpupreagg=off;
 EXPLAIN (ANALYZE, VERBOSE, COSTS OFF)
 SELECT grp, id FROM pgstrom_mvp_heap WHERE id > 0;")
partial_plan=$(<"$run_dir/low_uniform.analyze")
detail_rows=$(sed -nE 's/.*Gather Motion.*actual[^)]*rows=([0-9]+).*/\1/p' <<<"$detail_plan" | head -1)
partial_rows=$(sed -nE 's/.*Gather Motion.*actual[^)]*rows=([0-9]+).*/\1/p' <<<"$partial_plan" | head -1)
if [[ ! $detail_rows =~ ^[0-9]+$ || ! $partial_rows =~ ^[0-9]+$ ]]; then
    echo "could not demonstrate partial-row Motion reduction: detail=$detail_rows partial=$partial_rows" >&2
    exit 1
fi
if (( partial_rows >= detail_rows )); then
    echo "partial-row Motion did not reduce rows: detail=$detail_rows partial=$partial_rows" >&2
    exit 1
fi
echo "Motion rows: detail=$detail_rows GpuPreAgg-partial=$partial_rows"

echo "Cloudberry GpuPreAgg M4b normal-cost acceptance passed"
