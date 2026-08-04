#!/usr/bin/env bash
set -euo pipefail

psql_bin=${PSQL:-psql}
database=${PGDATABASE:-postgres}
target_content=${PGSTROM_MVP_TARGET_CONTENT:-0}
recovery_cycles=${PGSTROM_MVP_RECOVERY_CYCLES:-3}
recovery_timeout=${PGSTROM_MVP_RECOVERY_TIMEOUT:-30}
allow_restart=${PGSTROM_MVP_ALLOW_SERVICE_RESTART:-0}
allow_hard_failure=${PGSTROM_MVP_ALLOW_HARD_FAILURE:-0}
service_signal=${PGSTROM_MVP_SERVICE_SIGNAL:-HUP}

psql_cmd=("$psql_bin" -X -v ON_ERROR_STOP=1 -d "$database")

die() {
    echo "failure/recovery demo: $*" >&2
    exit 1
}

for numeric_setting in target_content recovery_cycles recovery_timeout; do
    numeric_value=${!numeric_setting}
    if [[ ! $numeric_value =~ ^[0-9]+$ ]]; then
        die "$numeric_setting must be a non-negative integer: $numeric_value"
    fi
done
if (( recovery_cycles < 1 || recovery_timeout < 5 )); then
    die "recovery cycles must be positive and timeout must be at least 5 seconds"
fi
if [[ $allow_restart != 1 ]]; then
    die "set PGSTROM_MVP_ALLOW_SERVICE_RESTART=1 to authorize signaling the target GPU Service"
fi
service_signal=${service_signal^^}
if [[ $service_signal != HUP && $service_signal != KILL ]]; then
    die "PGSTROM_MVP_SERVICE_SIGNAL must be HUP or KILL: $service_signal"
fi
if [[ $service_signal == KILL && $allow_hard_failure != 1 ]]; then
    die "set PGSTROM_MVP_ALLOW_HARD_FAILURE=1 to authorize SIGKILL fault injection"
fi

topology=$("${psql_cmd[@]}" -AtF '|' -c "
    SELECT count(DISTINCT content) FILTER (
               WHERE preferred_role = 'p' AND content >= 0),
           count(DISTINCT content) FILTER (
               WHERE role = 'p' AND preferred_role = 'p'
                 AND status = 'u' AND content >= 0)
    FROM gp_segment_configuration;")
IFS='|' read -r configured_primary_count primary_segment_count <<<"$topology"
if [[ ! $configured_primary_count =~ ^[0-9]+$ ||
      ! $primary_segment_count =~ ^[0-9]+$ ]]; then
    die "unable to determine primary topology: $topology"
fi
if (( configured_primary_count < 2 ||
      primary_segment_count != configured_primary_count )); then
    die "requires at least two up preferred primaries: configured=$configured_primary_count up=$primary_segment_count"
fi

segment_info=$("${psql_cmd[@]}" -AtF '|' -c "
    SELECT hostname, datadir, port, dbid
    FROM gp_segment_configuration
    WHERE content = $target_content
      AND role = 'p'
      AND preferred_role = 'p'
      AND status = 'u';")
IFS='|' read -r target_hostname target_datadir target_port target_dbid <<<"$segment_info"
if [[ -z ${target_hostname:-} || -z ${target_datadir:-} ||
      ! ${target_port:-} =~ ^[0-9]+$ || ! ${target_dbid:-} =~ ^[0-9]+$ ]]; then
    die "content $target_content is not an up preferred primary: $segment_info"
fi

local_hostname=$(hostname)
local_fqdn=$(hostname -f 2>/dev/null || hostname)
if [[ $target_hostname != "$local_hostname" && $target_hostname != "$local_fqdn" ]]; then
    die "target content $target_content is on $target_hostname; this process-level demo is single-host only"
fi
if [[ ! -r $target_datadir/postmaster.pid ]]; then
    die "cannot read target postmaster PID file: $target_datadir/postmaster.pid"
fi
read -r postmaster_pid <"$target_datadir/postmaster.pid"
if [[ ! $postmaster_pid =~ ^[0-9]+$ ]] || ! kill -0 "$postmaster_pid" 2>/dev/null; then
    die "invalid or stopped postmaster PID for content $target_content: $postmaster_pid"
fi

postmaster_args=$(ps -p "$postmaster_pid" -o args=)
if [[ $postmaster_args != *"$target_datadir"* ]]; then
    die "PID $postmaster_pid does not identify the expected postmaster: $postmaster_args"
fi

find_gpu_service_pid() {
    local matches
    local count

    matches=$(ps -o pid=,args= --ppid "$postmaster_pid" |
        awk '/PG-Strom GPU Service/ {print $1}')
    count=$(awk 'NF {n++} END {print n+0}' <<<"$matches")
    if (( count != 1 )); then
        return 1
    fi
    awk 'NF {print; exit}' <<<"$matches"
}

worker_log_count() {
    local worker_pattern=$1
    local matches

    if [[ ! -d $target_datadir/log ]]; then
        echo 0
        return
    fi
    matches=$(grep -h -F "$worker_pattern" "$target_datadir"/log/* 2>/dev/null || true)
    awk 'NF {n++} END {print n+0}' <<<"$matches"
}

wait_for_old_service_exit() {
    local old_pid=$1
    local deadline=$((SECONDS + recovery_timeout))

    while (( SECONDS < deadline )); do
        if ! kill -0 "$old_pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

wait_for_new_service() {
    local old_pid=$1
    local deadline=$((SECONDS + recovery_timeout))
    local candidate

    while (( SECONDS < deadline )); do
        candidate=$(find_gpu_service_pid || true)
        if [[ $candidate =~ ^[0-9]+$ && $candidate != "$old_pid" ]] &&
           kill -0 "$candidate" 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
        sleep 0.2
    done
    return 1
}

gpu_settings="
    SET optimizer=off;
    SET pg_strom.enabled=on;
    SET pg_strom.enable_gpuscan=on;
    SET pg_strom.cpu_fallback=off;
    SET statement_timeout='10s';
    SET enable_seqscan=off;"

signature_query="
    SELECT count(*) || '|' || coalesce(sum(id)::text,'') || '|' ||
           coalesce(sum(amount)::text,'') || '|' ||
           md5(string_agg(id::text || ':' || payload, ',' ORDER BY id))
    FROM pgstrom_mvp_heap
    WHERE grp BETWEEN 101 AND 207 AND amount >= 500.00;"

failure_query="
    SELECT 'UNEXPECTED_PARTIAL_RESULT|' || count(*) || '|' ||
           coalesce(sum(id)::text,'')
    FROM pgstrom_mvp_heap
    WHERE grp BETWEEN 101 AND 207 AND amount >= 500.00;"

if [[ $("${psql_cmd[@]}" -Atqc "SELECT to_regclass('public.pgstrom_mvp_heap') IS NOT NULL;") != t ]]; then
    die "pgstrom_mvp_heap is missing; run run_demo.sh successfully before this test"
fi
if [[ $("${psql_cmd[@]}" -Atqc "SELECT to_regclass('pgstrom.gpu_service_status') IS NOT NULL;") != t ]]; then
    die "pgstrom.gpu_service_status is missing; install PG-Strom 6.1 and ALTER EXTENSION pg_strom UPDATE"
fi

plan=$("${psql_cmd[@]}" -Atqc "
    $gpu_settings
    EXPLAIN (ANALYZE, VERBOSE, COSTS OFF) $signature_query")
if ! grep -q 'Custom Scan (GpuScan)' <<<"$plan" ||
   ! grep -Eq "Motion .*\\(slice[1-9][0-9]*; segments: ${primary_segment_count}\\)" <<<"$plan"; then
    die "baseline query is not a $primary_segment_count-primary GpuScan"
fi

cpu_signature=$("${psql_cmd[@]}" -Atqc "
    SET optimizer=off;
    SET pg_strom.enabled=off;
    $signature_query")
gpu_signature=$("${psql_cmd[@]}" -Atqc "$gpu_settings $signature_query")
if [[ $cpu_signature != "$gpu_signature" ]]; then
    die "baseline CPU/GPU mismatch: CPU=$cpu_signature GPU=$gpu_signature"
fi

max_async_tasks=$("${psql_cmd[@]}" -Atqc "SHOW pg_strom.max_async_tasks;")
if [[ ! $max_async_tasks =~ ^[0-9]+$ ]]; then
    die "invalid pg_strom.max_async_tasks value: $max_async_tasks"
fi
worker_pattern="workers - $max_async_tasks startup"

echo "Failure/recovery target: content=$target_content dbid=$target_dbid host=$target_hostname port=$target_port"
echo "Target postmaster: pid=$postmaster_pid datadir=$target_datadir"
echo "Baseline signature: $gpu_signature"
echo "Expected worker log pattern: $worker_pattern"
echo "Fault signal: SIG$service_signal"

for ((cycle = 1; cycle <= recovery_cycles; cycle++)); do
    old_service_pid=$(find_gpu_service_pid || true)
    if [[ ! $old_service_pid =~ ^[0-9]+$ ]]; then
        die "cycle $cycle: unable to identify exactly one GPU Service child of postmaster $postmaster_pid"
    fi
    old_worker_logs=$(worker_log_count "$worker_pattern")

    old_generation=$("${psql_cmd[@]}" -Atqc "
        SELECT min(service_generation)
        FROM pgstrom.gpu_service_status_segments()
        WHERE content_id = $target_content
        HAVING count(*) > 0
           AND min(service_generation) = max(service_generation);")
    if [[ ! $old_generation =~ ^[0-9]+$ ]]; then
        die "cycle $cycle: unable to read service generation for content $target_content: $old_generation"
    fi

    echo "cycle $cycle/$recovery_cycles: signaling GPU Service pid=$old_service_pid with SIG$service_signal"
    kill -"$service_signal" "$old_service_pid"
    if ! wait_for_old_service_exit "$old_service_pid"; then
        die "cycle $cycle: GPU Service $old_service_pid did not exit within ${recovery_timeout}s"
    fi

    set +e
    failure_output=$("${psql_cmd[@]}" -Atqc "$gpu_settings $failure_query" 2>&1)
    failure_status=$?
    set -e
    if (( failure_status == 0 )); then
        die "cycle $cycle: query unexpectedly succeeded while content $target_content GPU Service was down: $failure_output"
    fi
    if grep -q 'UNEXPECTED_PARTIAL_RESULT' <<<"$failure_output"; then
        die "cycle $cycle: query emitted a partial result before failing: $failure_output"
    fi
    if ! grep -Eiq 'failed on connect|gpu[ -]?service|gpuserv|pg_strom.*sock|segment.*(fail|error)|terminating connection|recovery mode' <<<"$failure_output"; then
        die "cycle $cycle: failure was not clearly attributed to GPU/segment service: $failure_output"
    fi
    echo "cycle $cycle/$recovery_cycles: distributed query failed without a partial row (expected)"
    printf '%s\n' "$failure_output" | tail -n 8

    new_service_pid=$(wait_for_new_service "$old_service_pid" || true)
    if [[ ! $new_service_pid =~ ^[0-9]+$ ]]; then
        die "cycle $cycle: replacement GPU Service did not start within ${recovery_timeout}s"
    fi

    recovery_deadline=$((SECONDS + recovery_timeout))
    recovered_signature=
    while (( SECONDS < recovery_deadline )); do
        set +e
        recovered_signature=$("${psql_cmd[@]}" -Atqc "$gpu_settings $signature_query" 2>/dev/null)
        recovery_status=$?
        set -e
        if (( recovery_status == 0 )); then
            break
        fi
        sleep 0.5
    done
    if [[ $recovered_signature != "$cpu_signature" ]]; then
        die "cycle $cycle: service restarted but signature did not recover: expected=$cpu_signature actual=$recovered_signature"
    fi

    new_generation=$("${psql_cmd[@]}" -Atqc "
        SELECT min(service_generation)
        FROM pgstrom.gpu_service_status_segments()
        WHERE content_id = $target_content
        HAVING count(*) > 0
           AND bool_and(ready AND actual_workers = configured_workers)
           AND min(service_generation) = max(service_generation);")
    if [[ ! $new_generation =~ ^[1-9][0-9]*$ ]]; then
        die "cycle $cycle: SQL status did not show a ready replacement generation: old=$old_generation new=$new_generation"
    fi
    generation_note=
    if [[ $service_signal == HUP ]]; then
        if (( new_generation <= old_generation )); then
            die "cycle $cycle: controlled restart did not advance service generation: old=$old_generation new=$new_generation"
        fi
    elif (( new_generation <= old_generation )); then
        # A SIGKILL of a BGWORKER_SHMEM_ACCESS process may make the Segment
        # postmaster run crash recovery and recreate shared memory.  Service
        # generation is monotonic only within one shared-memory epoch, so a
        # ready replacement PID, worker startup, and recovered signature are
        # the durable hard-failure checks when the counter resets.
        generation_note=" (shared-memory epoch reset after SIGKILL)"
    fi

    worker_deadline=$((SECONDS + recovery_timeout))
    new_worker_logs=$(worker_log_count "$worker_pattern")
    while (( new_worker_logs <= old_worker_logs && SECONDS < worker_deadline )); do
        sleep 0.2
        new_worker_logs=$(worker_log_count "$worker_pattern")
    done
    if (( new_worker_logs <= old_worker_logs )); then
        die "cycle $cycle: no new '$worker_pattern' message appeared in $target_datadir/log"
    fi

    if ! kill -0 "$postmaster_pid" 2>/dev/null; then
        die "cycle $cycle: target segment postmaster unexpectedly stopped"
    fi
    echo "cycle $cycle/$recovery_cycles: pid $old_service_pid -> $new_service_pid, status generation $old_generation -> $new_generation$generation_note, worker logs $old_worker_logs -> $new_worker_logs, signature recovered"
done

echo "GPU Service SIG$service_signal failure propagation and recovery passed for $recovery_cycles cycles on content $target_content."
