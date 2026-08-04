#!/usr/bin/env bash
set -euo pipefail

psql_bin=${PSQL:-psql}
database=${PGDATABASE:-postgres}
cancel_cycles=${PGSTROM_MVP_CANCEL_CYCLES:-3}
cancel_timeout=${PGSTROM_MVP_CANCEL_TIMEOUT:-30}
demo_app="pgstrom_mvp_cancel_$$"
output_file=$(mktemp /tmp/pgstrom-mvp-cancel.XXXXXX)
target_client_pid=

psql_cmd=("$psql_bin" -X -v ON_ERROR_STOP=1 -d "$database")

cleanup() {
    if [[ ${target_client_pid:-} =~ ^[0-9]+$ ]] && kill -0 "$target_client_pid" 2>/dev/null; then
        kill "$target_client_pid" 2>/dev/null || true
        wait "$target_client_pid" 2>/dev/null || true
    fi
    rm -f "$output_file"
}
trap cleanup EXIT

die() {
    echo "query-cancel demo: $*" >&2
    exit 1
}

for numeric_setting in cancel_cycles cancel_timeout; do
    numeric_value=${!numeric_setting}
    if [[ ! $numeric_value =~ ^[0-9]+$ ]]; then
        die "$numeric_setting must be a non-negative integer: $numeric_value"
    fi
done
if (( cancel_cycles < 1 || cancel_timeout < 5 )); then
    die "cancel cycles must be positive and timeout must be at least 5 seconds"
fi

if [[ $("${psql_cmd[@]}" -Atqc "SELECT to_regclass('public.pgstrom_mvp_heap') IS NOT NULL;") != t ]]; then
    die "pgstrom_mvp_heap is missing; run run_demo.sh successfully before this test"
fi
if [[ $("${psql_cmd[@]}" -Atqc "SELECT to_regclass('pgstrom.gpu_service_status') IS NOT NULL;") != t ]]; then
    die "pgstrom.gpu_service_status is missing; install PG-Strom 6.1 and ALTER EXTENSION pg_strom UPDATE"
fi

gpu_settings="
    SET optimizer=off;
    SET pg_strom.enabled=on;
    SET pg_strom.enable_gpuscan=on;
    SET pg_strom.cpu_fallback=off;
    SET enable_seqscan=off;"

# Probe the statement executed by every loop iteration independently.  A
# lateral SQL formulation is not suitable here because Cloudberry may insert
# a required Materialize node below Motion even with enable_material=off.  It
# would then run GpuScan only once and spend the remaining time filtering the
# cached rows on the CPU.
cancel_scan_query="
    SELECT count(*)
    FROM pgstrom_mvp_heap t
    WHERE t.grp = 1
      AND t.amount >= 250.00;"

# A server-side loop keeps one identifiable coordinator backend alive while
# executing a fresh distributed GpuScan statement on every iteration.  The
# loop is intentionally much longer than the cancellation timeout.  The
# comment is used only to identify this backend in pg_stat_activity.
cancel_query="
    /* pgstrom_mvp_cancel_target */
    DO \$pgstrom_cancel\$
    DECLARE
        target_grp integer;
    BEGIN
        FOR target_grp IN 1..100000 LOOP
            PERFORM count(*)
            FROM pgstrom_mvp_heap t
            WHERE t.grp = (target_grp % 900)
              AND t.amount >= 250.00;
        END LOOP;
    END
    \$pgstrom_cancel\$;"

signature_query="
    SELECT count(*) || '|' || coalesce(sum(id)::text,'') || '|' ||
           coalesce(sum(amount)::text,'')
    FROM pgstrom_mvp_heap
    WHERE grp BETWEEN 101 AND 207 AND amount >= 500.00;"

plan=$("${psql_cmd[@]}" -Atqc "$gpu_settings EXPLAIN (VERBOSE, COSTS OFF) $cancel_scan_query")
if ! grep -q 'Custom Scan (GpuScan)' <<<"$plan"; then
    die "cancel loop statement does not contain GpuScan: $plan"
fi

cpu_signature=$("${psql_cmd[@]}" -Atqc "
    SET optimizer=off;
    SET pg_strom.enabled=off;
    $signature_query")

read_segment_counters() {
    "${psql_cmd[@]}" -AtF '|' -qc "
        SELECT coalesce(sum(submitted_commands),0),
               coalesce(sum(completed_commands),0),
               coalesce(sum(failed_commands),0),
               coalesce(sum(cancelled_commands),0),
               coalesce(sum(queued_commands),0),
               coalesce(sum(active_commands),0),
               coalesce(sum(active_clients),0),
               bool_and(ready AND actual_workers = configured_workers)
        FROM pgstrom.gpu_service_status_segments();"
}

echo "Query-cancel baseline signature: $cpu_signature"

for ((cycle = 1; cycle <= cancel_cycles; cycle++)); do
    counters=$(read_segment_counters)
    IFS='|' read -r old_submitted old_completed old_failed old_cancelled old_queued old_active old_clients old_ready <<<"$counters"
    if [[ ! $old_submitted =~ ^[0-9]+$ || ! $old_completed =~ ^[0-9]+$ ||
          ! $old_failed =~ ^[0-9]+$ || ! $old_cancelled =~ ^[0-9]+$ ||
          ! $old_queued =~ ^[0-9]+$ || ! $old_active =~ ^[0-9]+$ ||
          ! $old_clients =~ ^[0-9]+$ || $old_ready != t ]]; then
        die "cycle $cycle: invalid or unready baseline service counters: $counters"
    fi
    if (( old_queued != 0 || old_active != 0 || old_clients != 0 )); then
        die "cycle $cycle: acceptance cluster is not idle at baseline: $counters"
    fi

    : >"$output_file"
    PGAPPNAME="$demo_app" "${psql_cmd[@]}" -c "$gpu_settings $cancel_query" >"$output_file" 2>&1 &
    target_client_pid=$!

    deadline=$((SECONDS + cancel_timeout))
    backend_pid=
    submitted=$old_submitted
    queued=0
    active=0
    clients=0
    ready=f
    observed_busy=0
    observed_client=0
    while (( SECONDS < deadline )); do
        backend_pid=$("${psql_cmd[@]}" -Atqc "
            SELECT pid
            FROM pg_stat_activity
            WHERE application_name = '$demo_app'
              AND state = 'active'
              AND query LIKE '%pgstrom_mvp_cancel_target%'
            ORDER BY backend_start DESC
            LIMIT 1;" || true)
        if [[ $backend_pid =~ ^[0-9]+$ ]]; then
            counters=$(read_segment_counters)
            IFS='|' read -r submitted _ _ _ queued active clients ready <<<"$counters"
            if [[ $submitted =~ ^[0-9]+$ && $queued =~ ^[0-9]+$ &&
                  $active =~ ^[0-9]+$ && $clients =~ ^[0-9]+$ &&
                  $ready == t ]]; then
                if (( queued + active > 0 )); then
                    observed_busy=1
                fi
                if (( clients > 0 )); then
                    observed_client=1
                fi
                # queued/active/client are instantaneous gauges sampled via
                # a distributed SQL query.  A fast GPU command can move
                # through all three states between samples.  submitted is a
                # monotonic counter, so its increase is the reliable signal
                # that this backend has reached GPU Service.  The target plan
                # is deliberately rescannable and the backend is still active
                # here; cancel it immediately instead of waiting for a gauge
                # value that may never be observed.
                if (( submitted > old_submitted )); then
                    break
                fi
            fi
        fi
        sleep 0.05
    done
    if [[ ! $backend_pid =~ ^[0-9]+$ ]]; then
        die "cycle $cycle: cancel target backend did not become active"
    fi
    if (( submitted <= old_submitted )); then
        die "cycle $cycle: no GPU command submission was observed before timeout: $counters"
    fi

    cancel_result=$("${psql_cmd[@]}" -Atqc "SELECT pg_cancel_backend($backend_pid);")
    if [[ $cancel_result != t ]]; then
        die "cycle $cycle: pg_cancel_backend($backend_pid) returned $cancel_result"
    fi

    deadline=$((SECONDS + cancel_timeout))
    new_submitted=$old_submitted
    new_completed=$old_completed
    new_failed=$old_failed
    new_cancelled=$old_cancelled
    queued=1
    active=1
    clients=1
    ready=f
    while kill -0 "$target_client_pid" 2>/dev/null && (( SECONDS < deadline )); do
        sleep 0.05
    done
    if kill -0 "$target_client_pid" 2>/dev/null; then
        die "cycle $cycle: cancelled psql client did not exit"
    fi
    set +e
    wait "$target_client_pid"
    cancel_status=$?
    set -e
    target_client_pid=
    if (( cancel_status == 0 )); then
        die "cycle $cycle: cancel target unexpectedly completed successfully"
    fi
    if ! grep -Eiq 'canceling statement|query canceled|cancelled' "$output_file"; then
        die "cycle $cycle: psql did not report query cancellation: $(tail -n 8 "$output_file")"
    fi

    deadline=$((SECONDS + cancel_timeout))
    while (( SECONDS < deadline )); do
        counters=$(read_segment_counters)
        IFS='|' read -r new_submitted new_completed new_failed new_cancelled queued active clients ready <<<"$counters"
        if [[ $new_submitted =~ ^[0-9]+$ && $new_completed =~ ^[0-9]+$ &&
              $new_failed =~ ^[0-9]+$ && $new_cancelled =~ ^[0-9]+$ &&
              $queued =~ ^[0-9]+$ && $active =~ ^[0-9]+$ &&
              $clients =~ ^[0-9]+$ && $ready == t ]] &&
           (( new_submitted > old_submitted &&
              new_completed - old_completed +
              new_failed - old_failed +
              new_cancelled - old_cancelled >= new_submitted - old_submitted &&
              queued == 0 && active == 0 && clients == 0 )); then
            break
        fi
        sleep 0.1
    done
    submitted_delta=$((new_submitted - old_submitted))
    completed_delta=$((new_completed - old_completed))
    failed_delta=$((new_failed - old_failed))
    cancelled_delta=$((new_cancelled - old_cancelled))
    terminal_delta=$((completed_delta + failed_delta + cancelled_delta))
    if (( submitted_delta <= 0 || terminal_delta < submitted_delta ||
          queued != 0 || active != 0 || clients != 0 )); then
        die "cycle $cycle: GPU commands did not drain after cancellation: $counters"
    fi

    gpu_signature=$("${psql_cmd[@]}" -Atqc "$gpu_settings $signature_query")
    if [[ $gpu_signature != "$cpu_signature" ]]; then
        die "cycle $cycle: post-cancel signature mismatch: CPU=$cpu_signature GPU=$gpu_signature"
    fi
    echo "cycle $cycle/$cancel_cycles: backend $backend_pid cancelled, submitted=$submitted_delta terminal=$terminal_delta (completed=$completed_delta failed=$failed_delta cancelled=$cancelled_delta), sampled_busy=$observed_busy sampled_client=$observed_client, queues drained, signature recovered"
done

echo "GpuScan query cancellation passed for $cancel_cycles cycles."
