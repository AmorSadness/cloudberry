#!/usr/bin/env bash
set -euo pipefail

psql_bin=${PSQL:-psql}
database=${PGDATABASE:-postgres}
client_count=${PGSTROM_SHARED_BUDGET_CLIENTS:-3}
poll_timeout=${PGSTROM_SHARED_BUDGET_TIMEOUT:-60}
require_rejection=${PGSTROM_SHARED_BUDGET_REQUIRE_REJECTION:-0}
psql_cmd=("$psql_bin" -X -v ON_ERROR_STOP=1 -d "$database")
run_dir=$(mktemp -d /tmp/pgstrom-shared-budget.XXXXXX)
app_prefix="pgstrom_shared_budget_$$"
pids=()

cleanup() {
	local pid deadline
	# Cancel only server backends started by this exact runner instance.  Killing
	# a local psql does not reliably cancel a distributed query.
	"${psql_cmd[@]}" -Atqc "
		SELECT pg_cancel_backend(pid)
		FROM pg_stat_activity
		WHERE application_name LIKE '${app_prefix}_%'
		  AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
    for pid in "${pids[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
	deadline=$((SECONDS + 10))
	while (( SECONDS < deadline )); do
		[[ $("${psql_cmd[@]}" -Atqc "
			SELECT count(*) FROM pg_stat_activity
			WHERE application_name LIKE '${app_prefix}_%';" 2>/dev/null || echo 1) == 0 ]] && break
		sleep 0.1
	done
	"${psql_cmd[@]}" -Atqc "
		SELECT pg_terminate_backend(pid)
		FROM pg_stat_activity
		WHERE application_name LIKE '${app_prefix}_%'
		  AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
    rm -rf "$run_dir"
}
trap cleanup EXIT INT TERM

if [[ ! $client_count =~ ^[0-9]+$ ]] || (( client_count < 2 )); then
    echo "PGSTROM_SHARED_BUDGET_CLIENTS must be at least 2: $client_count" >&2
    exit 1
fi
if [[ $require_rejection != 0 && $require_rejection != 1 ]]; then
    echo "PGSTROM_SHARED_BUDGET_REQUIRE_REJECTION must be 0 or 1" >&2
    exit 1
fi

status_sql="
    SELECT content_id, shared_budget_bytes, shared_reserved_bytes,
           local_reserved_bytes, budget_admissions, budget_rejections,
           budget_waits, stale_reclaims
    FROM pgstrom.gpu_service_status
    ORDER BY content_id, gpu_id;"

if ! "${psql_cmd[@]}" -Atqc "$status_sql" >"$run_dir/status.before"; then
    echo "pg_strom 6.2 status columns are unavailable; install and ALTER EXTENSION pg_strom UPDATE TO '6.2'" >&2
    exit 1
fi
if [[ -z $(<"$run_dir/status.before") ]]; then
    echo "no GPU Service status rows" >&2
    exit 1
fi

assert_budget_invariant() {
    local bad
    bad=$("${psql_cmd[@]}" -Atqc "
        SELECT count(*)
        FROM pgstrom.gpu_service_status
        WHERE NOT ready
           OR shared_budget_bytes <= 0
           OR shared_reserved_bytes > shared_budget_bytes;" || echo query_failed)
    if [[ $bad == query_failed || ! $bad =~ ^[0-9]+$ || $bad != 0 ]]; then
        echo "shared GPU budget invariant failed (bad rows: $bad)" >&2
        "${psql_cmd[@]}" -P pager=off -c "$status_sql" >&2 || true
        return 1
    fi
}

read_counter() {
    local column=$1
    "${psql_cmd[@]}" -Atqc "
        SELECT COALESCE(max($column), 0)
        FROM pgstrom.gpu_service_status;"
}

gpu_settings="
    SET optimizer=off;
    SET pg_strom.enabled=on;
    SET pg_strom.enable_gpuscan=on;
    SET pg_strom.enable_gpupreagg=on;
    SET pg_strom.enable_gpusort=off;
    SET pg_strom.enable_numeric_aggfuncs=off;
    SET pg_strom.enable_partitionwise_gpupreagg=off;
    SET pg_strom.cloudberry_enable_host_quals=off;
    SET pg_strom.cpu_fallback=off;"
test_query="
    SELECT grp, count(*), sum(id), min(id), max(id)
    FROM pgstrom_mvp_heap
    WHERE grp BETWEEN 101 AND 207 AND id > 0
    GROUP BY grp
    ORDER BY grp;"

if [[ $("${psql_cmd[@]}" -Atqc "SELECT to_regclass('pgstrom_mvp_heap') IS NOT NULL;") != t ]]; then
    echo "pgstrom_mvp_heap is missing; run run_demo.sh or setup.sql first" >&2
    exit 1
fi
plan=$("${psql_cmd[@]}" -Atqc "$gpu_settings EXPLAIN (VERBOSE, COSTS OFF) $test_query")
if ! grep -q 'Custom Scan (GpuPreAgg)' <<<"$plan"; then
    echo "concurrency query did not produce GpuPreAgg" >&2
    exit 1
fi

cpu_result=$("${psql_cmd[@]}" -AtF '|' -qc "
    SET optimizer=off; SET pg_strom.enabled=off; $test_query")
old_admissions=$(read_counter budget_admissions)
old_rejections=$(read_counter budget_rejections)
old_waits=$(read_counter budget_waits)
assert_budget_invariant

for ((i=1; i<=client_count; i++)); do
    (
		set +e
        "${psql_cmd[@]}" -AtF '|' -qc "
            SET application_name = '${app_prefix}_$i';
            $gpu_settings
            $test_query" >"$run_dir/client.$i.out" 2>"$run_dir/client.$i.err"
		rc=$?
		printf '%d\n' "$rc" >"$run_dir/client.$i.status"
		exit "$rc"
    ) &
    pids+=("$!")
done

deadline=$((SECONDS + poll_timeout))
while :; do
    live=0
	for ((i=1; i<=client_count; i++)); do
		if [[ ! -f "$run_dir/client.$i.status" ]]; then
            live=$((live + 1))
        fi
    done
    assert_budget_invariant
    (( live == 0 )) && break
    if (( SECONDS >= deadline )); then
        echo "concurrent budget workload timed out after ${poll_timeout}s" >&2
		"${psql_cmd[@]}" -P pager=off -c "
			SELECT pid, application_name, state, wait_event_type, wait_event,
			       now() - query_start AS elapsed
			FROM pg_stat_activity
			WHERE application_name LIKE '${app_prefix}_%'
			ORDER BY pid;" >&2 || true
		"${psql_cmd[@]}" -P pager=off -c "$status_sql" >&2 || true
        exit 1
    fi
    sleep 0.1
done

successes=0
failures=0
for ((i=1; i<=client_count; i++)); do
    if wait "${pids[i-1]}"; then
        if [[ $(<"$run_dir/client.$i.out") != "$cpu_result" ]]; then
            echo "client $i returned a result different from the CPU baseline" >&2
            diff -u <(printf '%s\n' "$cpu_result") "$run_dir/client.$i.out" >&2 || true
            exit 1
        fi
        successes=$((successes + 1))
    else
        error_text=$(tr '\n' ' ' <"$run_dir/client.$i.err")
        failures=$((failures + 1))
        echo "client $i was rejected: $error_text"
        if grep -q 'CUDA_ERROR_OUT_OF_MEMORY' "$run_dir/client.$i.err"; then
            echo "client $i reached a real CUDA OOM instead of being stopped by shared-budget admission" >&2
            exit 1
        fi
        if ! grep -q 'shared GPU budget admission rejected' "$run_dir/client.$i.err"; then
            echo "client $i failed for a reason other than shared-budget admission" >&2
            exit 1
        fi
    fi
done
pids=()

new_admissions=$(read_counter budget_admissions)
new_rejections=$(read_counter budget_rejections)
new_waits=$(read_counter budget_waits)
assert_budget_invariant
"${psql_cmd[@]}" -Atqc "$status_sql" >"$run_dir/status.after"

if (( successes == 0 || new_admissions <= old_admissions )); then
    echo "no concurrent query completed through GPU budget admission" >&2
    exit 1
fi
if (( require_rejection == 1 )) &&
   (( failures == 0 || new_rejections <= old_rejections )); then
    echo "no budget rejection observed; lower shared_gpu_budget_ratio or raise client count" >&2
    exit 1
fi
if (( failures > 0 && new_rejections <= old_rejections )); then
    echo "client failures occurred without a budget rejection counter" >&2
    exit 1
fi

echo "shared GPU budget concurrent acceptance passed: successes=$successes failures=$failures waits=$((new_waits-old_waits)) rejections=$((new_rejections-old_rejections))"
