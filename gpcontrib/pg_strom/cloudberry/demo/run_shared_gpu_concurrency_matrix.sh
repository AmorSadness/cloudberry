#!/usr/bin/env bash
set -euo pipefail

psql_bin=${PSQL:-psql}
database=${PGDATABASE:-postgres}
psql_cmd=("$psql_bin" -X -v ON_ERROR_STOP=1 -d "$database")
run_dir=$(mktemp -d /tmp/pgstrom-shared-matrix.XXXXXX)
pids=()

cleanup() {
    for pid in "${pids[@]:-}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
    "${psql_cmd[@]}" -Atqc \
        "SELECT pgstrom.shared_gpu_budget_inject_oom_segments(0, 0);" \
        >/dev/null 2>&1 || true
    rm -rf "$run_dir"
}
trap cleanup EXIT INT TERM

scan_settings="
 SET optimizer=off; SET pg_strom.enabled=on;
 SET pg_strom.enable_gpuscan=on; SET pg_strom.enable_gpupreagg=off;
 SET pg_strom.cpu_fallback=off;"
preagg_settings="
 SET optimizer=off; SET pg_strom.enabled=on;
 SET pg_strom.enable_gpuscan=on; SET pg_strom.enable_gpupreagg=on;
 SET pg_strom.enable_gpusort=off;
 SET pg_strom.enable_numeric_aggfuncs=off;
 SET pg_strom.enable_partitionwise_gpupreagg=off;
 SET pg_strom.cloudberry_enable_host_quals=off;
 SET pg_strom.cpu_fallback=off;"
scan_query="
 SELECT count(*) || '|' || coalesce(sum(id)::text,'') || '|' ||
        md5(string_agg(id::text || ':' || payload, ',' ORDER BY id))
 FROM pgstrom_mvp_heap
 WHERE grp BETWEEN 101 AND 207 AND amount >= 500.00;"
preagg_query="
 SELECT grp, count(*), sum(id), min(id), max(id)
 FROM pgstrom_mvp_heap
 WHERE grp BETWEEN 101 AND 207 AND id > 0
 GROUP BY grp ORDER BY grp;"

require_plan() {
    local operator=$1 settings=$2 query=$3 plan
    plan=$("${psql_cmd[@]}" -Atqc "$settings EXPLAIN (VERBOSE, COSTS OFF) $query")
    grep -q "Custom Scan ($operator)" <<<"$plan" || {
        echo "required $operator plan was not produced" >&2
        exit 1
    }
}

assert_idle_safe() {
    local bad deadline=$((SECONDS + 30))
    while :; do
        bad=$("${psql_cmd[@]}" -Atqc "
          SELECT count(*) FROM pgstrom.gpu_service_status
          WHERE NOT ready OR shared_reserved_bytes > shared_budget_bytes
             OR active_clients <> 0 OR queued_commands <> 0 OR active_commands <> 0;")
        [[ $bad == 0 ]] && return 0
        (( SECONDS < deadline )) || break
        sleep 0.1
    done
    [[ $bad == 0 ]] || {
        echo "GPU Service did not return to an idle, budget-safe state" >&2
        return 1
    }
}

assert_static_budget() {
    local bad
    bad=$("${psql_cmd[@]}" -Atqc "
      SELECT count(*) FROM pgstrom.gpu_service_status
      WHERE host_service_count < 2
         OR service_budget_bytes <= 0
         OR host_configured_budget_sum < service_budget_bytes
         OR safety_margin_bytes <= 0
         OR host_safe_capacity_bytes <> device_total_bytes - safety_margin_bytes
         OR shared_budget_bytes > host_safe_capacity_bytes
         OR budget_overcommitted;")
    [[ $bad == 0 ]] || {
        echo "P0a static host-budget diagnostics reported an unsafe configuration" >&2
        "${psql_cmd[@]}" -P pager=off -c "
          SELECT content_id, host_service_count,
                 pg_size_pretty(service_budget_bytes) AS service_budget,
                 pg_size_pretty(host_configured_budget_sum) AS theoretical_sum,
                 pg_size_pretty(safety_margin_bytes) AS safety_margin,
                 pg_size_pretty(host_safe_capacity_bytes) AS safe_capacity,
                 budget_overcommitted
          FROM pgstrom.gpu_service_status ORDER BY content_id, gpu_id;" >&2
        return 1
    }
}

run_pair() {
    local label=$1 settings1=$2 query1=$3 baseline1=$4
    local settings2=$5 query2=$6 baseline2=$7
    pids=()
    ("${psql_cmd[@]}" -AtF '|' -qc "$settings1 $query1" >"$run_dir/$label.1") & pids+=("$!")
    ("${psql_cmd[@]}" -AtF '|' -qc "$settings2 $query2" >"$run_dir/$label.2") & pids+=("$!")
    wait "${pids[0]}" || { echo "$label client 1 failed" >&2; exit 1; }
    wait "${pids[1]}" || { echo "$label client 2 failed" >&2; exit 1; }
    pids=()
    [[ $(<"$run_dir/$label.1") == "$baseline1" ]] || { echo "$label client 1 mismatch" >&2; exit 1; }
    [[ $(<"$run_dir/$label.2") == "$baseline2" ]] || { echo "$label client 2 mismatch" >&2; exit 1; }
    assert_idle_safe
    echo "$label: both results matched and resources drained"
}

require_plan GpuScan "$scan_settings" "$scan_query"
require_plan GpuPreAgg "$preagg_settings" "$preagg_query"
scan_cpu=$("${psql_cmd[@]}" -AtF '|' -qc "SET optimizer=off; SET pg_strom.enabled=off; $scan_query")
preagg_cpu=$("${psql_cmd[@]}" -AtF '|' -qc "SET optimizer=off; SET pg_strom.enabled=off; $preagg_query")
assert_idle_safe
assert_static_budget

run_pair gpuscan_gpuscan "$scan_settings" "$scan_query" "$scan_cpu" \
                         "$scan_settings" "$scan_query" "$scan_cpu"
run_pair gpuscan_gpupreagg "$scan_settings" "$scan_query" "$scan_cpu" \
                           "$preagg_settings" "$preagg_query" "$preagg_cpu"
request_traced=$("${psql_cmd[@]}" -Atqc "
  SELECT bool_and(last_request_bytes >= 16777216 AND
                  last_request_bytes < 1073741824)
  FROM pgstrom.gpu_service_status WHERE content_id >= 0;")
[[ $request_traced == t ]] || {
    echo "P0b did not expose an adaptive sub-1GiB GpuPreAgg request" >&2
    exit 1
}
echo "planner-derived adaptive GpuPreAgg request is visible in admission status"

# Arm one post-reservation failure on every Segment.  A distributed query may
# stop after the first QE error, so cleanup always disarms unused injections.
reserved_before=$("${psql_cmd[@]}" -Atqc \
    "SELECT max(shared_reserved_bytes) FROM pgstrom.gpu_service_status;")
"${psql_cmd[@]}" -Atqc \
    "SELECT pgstrom.shared_gpu_budget_inject_oom_segments(0, 1);" >/dev/null
if "${psql_cmd[@]}" -Atqc "$preagg_settings $preagg_query" \
      >"$run_dir/injected.out" 2>"$run_dir/injected.err"; then
    echo "injected allocation failure unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'injected query-buffer allocation failure after budget reservation' \
    "$run_dir/injected.err" || {
    echo "injected query did not report the expected allocation failure" >&2
    sed -n '1,20p' "$run_dir/injected.err" >&2
    exit 1
}
[[ ! -s "$run_dir/injected.out" ]] || {
    echo "injected allocation failure returned an unexpected partial result" >&2
    sed -n '1,20p' "$run_dir/injected.out" >&2
    exit 1
}
"${psql_cmd[@]}" -Atqc \
    "SELECT pgstrom.shared_gpu_budget_inject_oom_segments(0, 0);" >/dev/null
deadline=$((SECONDS + 30))
while :; do
    reserved_after=$("${psql_cmd[@]}" -Atqc \
        "SELECT max(shared_reserved_bytes) FROM pgstrom.gpu_service_status;")
    [[ $reserved_after == "$reserved_before" ]] && break
    (( SECONDS < deadline )) || break
    sleep 0.1
done
[[ $reserved_after == "$reserved_before" ]] || {
    echo "injected allocation failure leaked reservation: $reserved_before -> $reserved_after" >&2
    exit 1
}
assert_idle_safe
recovered=$("${psql_cmd[@]}" -AtF '|' -qc "$preagg_settings $preagg_query")
[[ $recovered == "$preagg_cpu" ]] || { echo "post-injection recovery mismatch" >&2; exit 1; }
assert_idle_safe
echo "injected allocation failure: no leak, no partial result, subsequent GpuPreAgg recovered"

echo "Cloudberry shared-GPU P0a/P0c concurrency matrix passed"
