#!/usr/bin/env bash
set -euo pipefail

psql_bin=${PSQL:-psql}
database=${PGDATABASE:-postgres}
repeat_count=${PGSTROM_GPUPREAGG_M5A_REPEAT:-3}
psql_cmd=("$psql_bin" -X -v ON_ERROR_STOP=1 -d "$database")
run_dir=$(mktemp -d /tmp/pgstrom-gpupreagg-m5a.XXXXXX)
trap 'rm -rf "$run_dir"' EXIT INT TERM

if [[ ! $repeat_count =~ ^[1-9][0-9]*$ ]]; then
    echo "PGSTROM_GPUPREAGG_M5A_REPEAT must be a positive integer: $repeat_count" >&2
    exit 1
fi

if [[ $("${psql_cmd[@]}" -Atqc \
    "SELECT to_regclass('pgstrom_mvp_colocated') IS NOT NULL;") != t ]]; then
    echo "pgstrom_mvp_colocated is missing; rerun cloudberry/demo/setup.sql" >&2
    exit 1
fi

primary_segment_count=$("${psql_cmd[@]}" -Atqc \
    "SELECT count(*) FROM gp_segment_configuration
     WHERE role='p' AND preferred_role='p' AND status='u' AND content >= 0;")
if [[ ! $primary_segment_count =~ ^[0-9]+$ ]] || (( primary_segment_count < 2 )); then
    echo "M5a requires at least two up preferred Primary segments" >&2
    exit 1
fi

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
 SELECT dist_key, count(*), sum(id), min(metric), max(metric)
 FROM pgstrom_mvp_colocated WHERE id > 0
 GROUP BY dist_key"
noncolocated_query="
 SELECT grp, count(*), sum(id), min(metric), max(metric)
 FROM pgstrom_mvp_colocated WHERE id > 0
 GROUP BY grp"

stable_plan() {
    local label=$1 query=$2 iteration plan first=
    for ((iteration = 1; iteration <= repeat_count; iteration++)); do
        plan=$("${psql_cmd[@]}" -Atqc \
            "$normal_settings EXPLAIN (VERBOSE, COSTS OFF) $query")
        printf '%s\n' "$plan" >"$run_dir/$label.$iteration.plan"
        if [[ -z $first ]]; then
            first=$plan
        elif [[ $plan != "$first" ]]; then
            echo "$label plan changed between identical planning attempts" >&2
            diff -u "$run_dir/$label.1.plan" "$run_dir/$label.$iteration.plan" >&2 || true
            exit 1
        fi
    done
    grep -q 'Custom Scan (GpuPreAgg)' <<<"$first" || {
        echo "$label should select GpuPreAgg with normal costs" >&2
        exit 1
    }
    printf '\n[%s plan]\n%s\n' "$label" "$first"
}

assert_final_shape() {
    local label=$1 expect_motion=$2 plan_file="$run_dir/$label.1.plan"
    local agg_line gpu_line between
    agg_line=$(grep -n 'Aggregate' \
        "$plan_file" | head -1 | cut -d: -f1)
    gpu_line=$(grep -n 'Custom Scan (GpuPreAgg)' "$plan_file" | head -1 | cut -d: -f1)
    if [[ ! $agg_line =~ ^[0-9]+$ || ! $gpu_line =~ ^[0-9]+$ ]] ||
       (( agg_line >= gpu_line )); then
        echo "$label does not contain CPU final aggregate above GpuPreAgg" >&2
        exit 1
    fi
    between=$(sed -n "${agg_line},${gpu_line}p" "$plan_file")
    if [[ $expect_motion == no ]]; then
        if grep -q 'Gather Motion' <<<"$between"; then
            echo "$label unexpectedly gathers partial rows before CPU final aggregate" >&2
            exit 1
        fi
        echo "$label: colocated CPU local final has no pre-final Gather Motion"
    else
        if ! grep -q 'Gather Motion' <<<"$between"; then
            echo "$label must retain Gather Motion for cross-Segment groups" >&2
            exit 1
        fi
        echo "$label: non-colocated CPU final retained Gather Motion"
    fi
}

compare_result_digest() {
    local label=$1 query=$2 cpu_digest gpu_digest
    cpu_digest=$("${psql_cmd[@]}" -AtF '|' -qc \
        "SET optimizer=off; SET pg_strom.enabled=off;
         SELECT * FROM ($query) AS q ORDER BY 1;" | sha256sum)
    gpu_digest=$("${psql_cmd[@]}" -AtF '|' -qc \
        "$normal_settings SELECT * FROM ($query) AS q ORDER BY 1;" | sha256sum)
    if [[ $cpu_digest != "$gpu_digest" ]]; then
        echo "$label CPU/GPU result digest mismatch" >&2
        exit 1
    fi
    echo "$label: CPU/GPU result digest matched"
}

stable_plan colocated "$colocated_query"
stable_plan noncolocated "$noncolocated_query"
assert_final_shape colocated no
assert_final_shape noncolocated yes
compare_result_digest colocated "$colocated_query"
compare_result_digest noncolocated "$noncolocated_query"

analyzed=$("${psql_cmd[@]}" -Atqc \
    "$normal_settings EXPLAIN (ANALYZE, VERBOSE, COSTS ON) $colocated_query")
printf '\n[colocated analyzed plan]\n%s\n' "$analyzed"
grep -q 'Custom Scan (GpuPreAgg)' <<<"$analyzed" || {
    echo "colocated EXPLAIN ANALYZE lost GpuPreAgg" >&2
    exit 1
}
grep -Eq 'GpuPreAgg Actual:.*groups actual/estimate:' <<<"$analyzed" || {
    echo "colocated plan did not return QE GpuPreAgg actual statistics" >&2
    exit 1
}

echo "Cloudberry GpuPreAgg M5a colocated local-final acceptance passed"
