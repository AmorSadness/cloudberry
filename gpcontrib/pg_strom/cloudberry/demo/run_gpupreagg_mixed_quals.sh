#!/usr/bin/env bash
set -euo pipefail

psql_bin=${PSQL:-psql}
database=${PGDATABASE:-postgres}
repeat_count=${PGSTROM_GPUPREAGG_MIXED_REPEAT:-3}
psql_cmd=("$psql_bin" -X -v ON_ERROR_STOP=1 -d "$database")
run_dir=$(mktemp -d /tmp/pgstrom-gpupreagg-mixed.XXXXXX)
trap 'rm -rf "$run_dir"' EXIT INT TERM

if [[ ! $repeat_count =~ ^[1-9][0-9]*$ ]]; then
    echo "PGSTROM_GPUPREAGG_MIXED_REPEAT must be a positive integer: $repeat_count" >&2
    exit 1
fi

for relation in pgstrom_mvp_heap pgstrom_mvp_colocated; do
    if [[ $("${psql_cmd[@]}" -Atqc \
        "SELECT to_regclass('$relation') IS NOT NULL;") != t ]]; then
        echo "$relation is missing; rerun cloudberry/demo/setup.sql" >&2
        exit 1
    fi
done

primary_segment_count=$("${psql_cmd[@]}" -Atqc "
    SELECT count(*) FROM gp_segment_configuration
    WHERE role='p' AND preferred_role='p' AND status='u' AND content >= 0;")
if [[ ! $primary_segment_count =~ ^[0-9]+$ ]] || (( primary_segment_count < 2 )); then
    echo "GpuPreAgg mixed quals requires at least two up preferred Primary segments" >&2
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
 SET pg_strom.cloudberry_enable_host_quals=on;
 SET pg_strom.cpu_fallback=off;
 SET enable_seqscan=off;
 SET gp_enable_multiphase_agg=off;
 SET pg_strom.gpu_setup_cost=0;
 SET pg_strom.gpu_tuple_cost=0;
 SET pg_strom.gpu_operator_cost=0;
 SET gp_motion_cost_per_row=1000000;
 SET cpu_tuple_cost=10;
 SET cpu_operator_cost=10;"

native_settings="
 SET optimizer=off;
 SET pg_strom.enabled=on;
 SET pg_strom.enable_gpuscan=on;
 SET pg_strom.enable_gpupreagg=on;
 SET pg_strom.cloudberry_enable_host_quals=off;"

colocated_query="
 SELECT dist_key, count(*), sum(id), min(metric), max(metric)
 FROM pgstrom_mvp_colocated
 WHERE id > 0 AND metric::text ~ '^-?[0-4]'
 GROUP BY dist_key"
noncolocated_query="
 SELECT grp, count(*), sum(id), min(id), max(id)
 FROM pgstrom_mvp_heap
 WHERE id > 0 AND payload ~ '^[0-7]'
 GROUP BY grp"
global_query="
 SELECT count(*), sum(id), min(id), max(id)
 FROM pgstrom_mvp_heap
 WHERE id > 0 AND payload ~ '^[89a-f]'"
having_query="
 SELECT grp, count(*), sum(id)
 FROM pgstrom_mvp_heap
 WHERE id > 0 AND payload ~ '^[0-7]'
 GROUP BY grp
 HAVING sum(id) > 0"

stable_mixed_plan() {
    local label=$1 query=$2 expect_motion=$3
    local iteration plan first= plan_file gpu_line scan_line filter_line agg_line between

    for ((iteration = 1; iteration <= repeat_count; iteration++)); do
        plan=$("${psql_cmd[@]}" -Atqc \
            "$feature_settings EXPLAIN (VERBOSE, COSTS OFF) $query")
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

    printf '\n[%s GpuPreAgg mixed-quals plan]\n%s\n' "$label" "$first"
    grep -q 'Custom Scan (GpuPreAgg)' <<<"$first" || {
        echo "$label did not produce GpuPreAgg" >&2
        echo "[$label PG-Strom planner diagnostics]" >&2
        "${psql_cmd[@]}" -Atqc \
            "SET client_min_messages = debug1; $feature_settings EXPLAIN (VERBOSE, COSTS ON) $query" \
            >&2 || true
        exit 1
    }
    grep -q 'Pre-Aggregation Input: CPU host-filtered GpuScan rows' <<<"$first" || {
        echo "$label did not expose the CPU-filtered row input boundary" >&2
        exit 1
    }
    grep -q 'Custom Scan (GpuScan)' <<<"$first" || {
        echo "$label did not retain the mixed-qual GpuScan child" >&2
        exit 1
    }
    grep -q 'GPU Scan Quals:' <<<"$first" || {
        echo "$label lost its device scan predicate" >&2
        exit 1
    }
    grep -Eq 'Filter:.*(~|regex)' <<<"$first" || {
        echo "$label did not attach the CPU host filter to GpuScan" >&2
        exit 1
    }

    gpu_line=$(grep -n 'Custom Scan (GpuPreAgg)' "$plan_file" | head -1 | cut -d: -f1)
    scan_line=$(grep -n 'Custom Scan (GpuScan)' "$plan_file" | head -1 | cut -d: -f1)
    filter_line=$(grep -n -E 'Filter:.*(~|regex)' "$plan_file" | head -1 | cut -d: -f1)
    agg_line=$(grep -n 'Aggregate' "$plan_file" | head -1 | cut -d: -f1)
    if [[ ! $gpu_line =~ ^[0-9]+$ || ! $scan_line =~ ^[0-9]+$ ||
          ! $filter_line =~ ^[0-9]+$ || ! $agg_line =~ ^[0-9]+$ ]] ||
       (( agg_line >= gpu_line || gpu_line >= scan_line || scan_line >= filter_line )); then
        echo "$label host qual is not below GpuPreAgg and before partial aggregation" >&2
        exit 1
    fi
    between=$(sed -n "${agg_line},${gpu_line}p" "$plan_file")
    if [[ $expect_motion == yes ]]; then
        grep -q 'Gather Motion' <<<"$between" || {
            echo "$label must retain Gather-final" >&2
            exit 1
        }
    else
        ! grep -q 'Gather Motion' <<<"$between" || {
            echo "$label unexpectedly gathered before its colocated final" >&2
            exit 1
        }
    fi
}

compare_digest() {
    local label=$1 query=$2 cpu_digest gpu_digest
    cpu_digest=$("${psql_cmd[@]}" -AtF '|' -qc \
        "SET optimizer=off; SET pg_strom.enabled=off;
         SELECT * FROM ($query) q ORDER BY 1;" | sha256sum)
    gpu_digest=$("${psql_cmd[@]}" -AtF '|' -qc \
        "$feature_settings SELECT * FROM ($query) q ORDER BY 1;" | sha256sum)
    [[ $cpu_digest == "$gpu_digest" ]] || {
        echo "$label CPU/GPU result digest mismatch" >&2
        exit 1
    }
    echo "$label: CPU/GPU result digest matched"
}

require_native() {
    local label=$1 settings=$2 query=$3 plan
    plan=$("${psql_cmd[@]}" -Atqc "$settings EXPLAIN (VERBOSE, COSTS OFF) $query")
    if grep -q 'Custom Scan (GpuPreAgg)' <<<"$plan"; then
        echo "$label unexpectedly produced GpuPreAgg" >&2
        exit 1
    fi
    echo "$label: safely retained native aggregate"
}

stable_mixed_plan colocated "$colocated_query" no
stable_mixed_plan noncolocated "$noncolocated_query" yes
stable_mixed_plan global "$global_query" yes
stable_mixed_plan having "$having_query" yes

compare_digest colocated "$colocated_query"
compare_digest noncolocated "$noncolocated_query"
compare_digest global "$global_query"
compare_digest having "$having_query"

require_native "mixed quals with opt-in GUC off" "$native_settings" "$noncolocated_query"
require_native "host-only qual" "$feature_settings" \
    "SELECT grp, count(*) FROM pgstrom_mvp_heap
     WHERE payload ~ '^[0-7]' GROUP BY grp"

echo "Cloudberry GpuPreAgg mixed host/device quals acceptance passed"
