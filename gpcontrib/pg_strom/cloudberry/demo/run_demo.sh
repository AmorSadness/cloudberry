#!/usr/bin/env bash
set -euo pipefail

psql_bin=${PSQL:-psql}
database=${PGDATABASE:-postgres}
repeat_count=${PGSTROM_MVP_REPEAT:-3}
ready_timeout=${PGSTROM_MVP_READY_TIMEOUT:-60}
demo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

psql_cmd=("$psql_bin" -X -v ON_ERROR_STOP=1 -d "$database")

if [[ ! $repeat_count =~ ^[1-9][0-9]*$ ]]; then
    echo "PGSTROM_MVP_REPEAT must be a positive integer: $repeat_count" >&2
    exit 1
fi
if [[ ! $ready_timeout =~ ^[1-9][0-9]*$ ]]; then
    echo "PGSTROM_MVP_READY_TIMEOUT must be a positive integer: $ready_timeout" >&2
    exit 1
fi

topology=$(
    "${psql_cmd[@]}" -AtF '|' -c "
        SELECT count(DISTINCT content) FILTER (
                   WHERE preferred_role = 'p' AND content >= 0),
               count(DISTINCT content) FILTER (
                   WHERE role = 'p' AND preferred_role = 'p'
                     AND status = 'u' AND content >= 0)
        FROM gp_segment_configuration;"
)
IFS='|' read -r configured_primary_count primary_segment_count <<<"$topology"
if [[ ! $configured_primary_count =~ ^[0-9]+$ ||
      ! $primary_segment_count =~ ^[0-9]+$ ]]; then
    echo "unable to determine the Cloudberry primary topology: $topology" >&2
    exit 1
fi
if (( primary_segment_count != configured_primary_count )); then
    echo "not all preferred primary segments are up: configured=$configured_primary_count up=$primary_segment_count" >&2
    exit 1
fi
if (( primary_segment_count < 2 )); then
    echo "the multi-segment demo requires at least two up preferred primaries; found $primary_segment_count" >&2
    exit 1
fi

echo "Cloudberry PG-Strom topology: $primary_segment_count up preferred primary segments"
"${psql_cmd[@]}" -P pager=off -c "
    SELECT content, hostname, port, role, preferred_role, status
    FROM gp_segment_configuration
    WHERE content >= 0
    ORDER BY content, preferred_role;"

"${psql_cmd[@]}" -f "$demo_dir/setup.sql"

if [[ $("${psql_cmd[@]}" -Atqc "SELECT to_regclass('pgstrom.gpu_service_status') IS NOT NULL;") != t ]]; then
    echo "pgstrom.gpu_service_status is missing; install PG-Strom 6.1 and ALTER EXTENSION pg_strom UPDATE" >&2
    exit 1
fi
read_service_summary() {
    "${psql_cmd[@]}" -AtF '|' -qc "
        SELECT count(DISTINCT content_id) FILTER (WHERE content_id >= 0),
               count(DISTINCT content_id) FILTER (WHERE content_id = -1),
               coalesce(bool_and(ready AND
                                 actual_workers = configured_workers), false),
               count(*)
        FROM pgstrom.gpu_service_status;"
}

print_service_diagnostics() {
    "${psql_cmd[@]}" -P pager=off -c "
        WITH expected(content_id) AS (
            VALUES (-1)
            UNION ALL
            SELECT content
            FROM gp_segment_configuration
            WHERE role = 'p' AND preferred_role = 'p'
              AND status = 'u' AND content >= 0
        ), observed AS (
            SELECT content_id,
                   count(*) AS devices,
                   bool_and(ready) AS ready,
                   string_agg(service_pid::text, ',' ORDER BY gpu_id) AS service_pids,
                   string_agg(service_generation::text, ',' ORDER BY gpu_id) AS generations,
                   string_agg(actual_workers::text || '/' ||
                              configured_workers::text, ',' ORDER BY gpu_id) AS workers,
                   sum(active_clients) AS clients,
                   sum(queued_commands) AS queued,
                   sum(active_commands) AS active,
                   string_agg(device_name, ',' ORDER BY gpu_id) AS device_names
            FROM pgstrom.gpu_service_status
            GROUP BY content_id
        )
        SELECT e.content_id,
               coalesce(o.devices::text, '<missing>') AS devices,
               coalesce(o.ready::text, '<missing>') AS ready,
               coalesce(o.service_pids, '<missing>') AS service_pids,
               coalesce(o.generations, '<missing>') AS generations,
               coalesce(o.workers, '<missing>') AS workers,
               coalesce(o.clients::text, '<missing>') AS clients,
               coalesce(o.queued::text, '<missing>') AS queued,
               coalesce(o.active::text, '<missing>') AS active,
               coalesce(o.device_names, '<missing>') AS device_names
        FROM expected e
        LEFT JOIN observed o USING (content_id)
        ORDER BY e.content_id;" || true
}

deadline=$((SECONDS + ready_timeout))
service_status=
status_primary_count=0
status_qd_count=0
status_ready=f
status_rows=0
while (( SECONDS < deadline )); do
    service_status=$(read_service_summary || true)
    IFS='|' read -r status_primary_count status_qd_count status_ready status_rows <<<"$service_status"
    if [[ $status_primary_count == "$primary_segment_count" &&
          $status_qd_count == 1 && $status_ready == t &&
          $status_rows =~ ^[1-9][0-9]*$ ]]; then
        break
    fi
    sleep 0.2
done
if [[ $status_primary_count != "$primary_segment_count" ||
      $status_qd_count != 1 || $status_ready != t ||
      ! $status_rows =~ ^[1-9][0-9]*$ ]]; then
    echo "GPU Service readiness timed out after ${ready_timeout}s: ${service_status:-<no status>}" >&2
    print_service_diagnostics >&2
    exit 1
fi
echo "GPU Service status: primaries=$status_primary_count coordinator=$status_qd_count rows=$status_rows ready=$status_ready"

gpu_settings="
    SET optimizer=off;
    SET pg_strom.enabled=on;
    SET pg_strom.enable_gpuscan=on;
    SET pg_strom.enable_gpupreagg=off;
    SET pg_strom.cpu_fallback=off;
    SET enable_seqscan=off;"
mixed_gpu_settings="
    $gpu_settings
    SET pg_strom.cloudberry_enable_host_quals=on;"

require_distribution_shape() {
    local label=$1
    local relation=$2
    local expected_nonempty=$3
    local distribution
    local nonempty

    distribution=$("${psql_cmd[@]}" -AtF '|' -c "
        SET pg_strom.enabled=off;
        SELECT count(*),
               string_agg(gp_segment_id::text || ':' || n::text,
                          ',' ORDER BY gp_segment_id)
        FROM (
            SELECT gp_segment_id, count(*) AS n
            FROM $relation
            GROUP BY gp_segment_id
        ) AS per_segment;")
    distribution=${distribution##*$'\n'}
    nonempty=${distribution%%|*}
    if [[ $nonempty != "$expected_nonempty" ]]; then
        echo "$label has an unexpected distribution: $distribution (expected $expected_nonempty nonempty segments)" >&2
        exit 1
    fi
    echo "$label distribution: ${distribution#*|}"
}

require_gpuscan_plan() {
    local label=$1
    local query=$2
    local plan_settings=${3:-$gpu_settings}
    local plan

    plan=$("${psql_cmd[@]}" -Atqc "
        $plan_settings
        EXPLAIN (ANALYZE, VERBOSE, COSTS OFF) $query")
    printf '\n[%s plan]\n%s\n' "$label" "$plan"
    if ! grep -q 'Custom Scan (GpuScan)' <<<"$plan"; then
        echo "$label did not produce a GpuScan" >&2
        exit 1
    fi
    if ! grep -Eq "Motion .*\\(slice[1-9][0-9]*; segments: ${primary_segment_count}\\)" <<<"$plan"; then
        echo "$label does not show GpuScan below a $primary_segment_count-primary QE Motion" >&2
        exit 1
    fi
}

require_mixed_quals_plan() {
    local label=$1
    local query=$2
    local plan

    plan=$("${psql_cmd[@]}" -Atqc "
        $mixed_gpu_settings
        EXPLAIN (ANALYZE, VERBOSE, COSTS OFF) $query")
    printf '\n[%s mixed-quals plan]\n%s\n' "$label" "$plan"
    if ! grep -q 'Custom Scan (GpuScan)' <<<"$plan"; then
        echo "$label did not produce a mixed-quals GpuScan" >&2
        exit 1
    fi
    if ! grep -q 'GPU Scan Quals:' <<<"$plan" ||
       ! grep -q 'Filter:' <<<"$plan" ||
       ! grep -q 'payload.*~' <<<"$plan"; then
        echo "$label did not expose both GPU Scan Quals and a host Filter" >&2
        exit 1
    fi
    if ! grep -Eq "Motion .*\\(slice[1-9][0-9]*; segments: ${primary_segment_count}\\)" <<<"$plan"; then
        echo "$label does not show mixed-quals GpuScan below a $primary_segment_count-primary QE Motion" >&2
        exit 1
    fi
}

compare_signature() {
    local label=$1
    local query=$2
    local plan_settings=${3:-$gpu_settings}
    local cpu
    local gpu
    local iteration
    local started_ns
    local finished_ns
    local elapsed_ms

    cpu=$("${psql_cmd[@]}" -Atqc "
        SET optimizer=off;
        SET pg_strom.enabled=off;
        $query")
    echo "$label CPU signature: $cpu"

    for ((iteration = 1; iteration <= repeat_count; iteration++)); do
        started_ns=$(date +%s%N)
        gpu=$("${psql_cmd[@]}" -Atqc "
            $plan_settings
            $query")
        finished_ns=$(date +%s%N)
        elapsed_ms=$(((finished_ns - started_ns) / 1000000))
        if [[ $cpu != "$gpu" ]]; then
            echo "$label CPU/GPU signature mismatch on iteration $iteration: CPU=$cpu GPU=$gpu" >&2
            exit 1
        fi
        echo "$label GPU iteration $iteration/$repeat_count: ${elapsed_ms}ms signature=$gpu"
    done
}

require_distribution_shape "uniform heap" pgstrom_mvp_heap "$primary_segment_count"
require_distribution_shape "skew heap" pgstrom_mvp_skew 1
require_distribution_shape "small heap" pgstrom_mvp_small 1

uniform_signature="
    SELECT count(*) || '|' || coalesce(sum(id)::text,'') || '|' ||
           coalesce(sum(amount)::text,'') || '|' ||
           md5(string_agg(id::text || ':' || payload, ',' ORDER BY id))
    FROM pgstrom_mvp_heap
    WHERE grp BETWEEN 101 AND 207 AND amount >= 500.00;"
skew_signature="
    SELECT count(*) || '|' || coalesce(sum(id)::text,'') || '|' ||
           coalesce(sum(metric)::text,'') || '|' ||
           coalesce(sum(amount)::text,'') || '|' ||
           count(*) FILTER (WHERE nullable_metric IS NULL) || '|' ||
           count(*) FILTER (WHERE payload IS NULL) || '|' ||
           md5(string_agg(id::text || ':' ||
                          coalesce(nullable_metric::text, '<NULL>') || ':' ||
                          coalesce(payload, '<NULL>'), ',' ORDER BY id))
    FROM pgstrom_mvp_skew
    WHERE metric BETWEEN -500 AND 750 AND amount >= -250.00;"
small_signature="
    SELECT count(*) || '|' || coalesce(sum(id)::text,'') || '|' ||
           coalesce(sum(metric)::text,'') || '|' ||
           coalesce(sum(amount)::text,'') || '|' ||
           count(*) FILTER (WHERE nullable_metric IS NULL) || '|' ||
           count(*) FILTER (WHERE payload IS NULL) || '|' ||
           md5(string_agg(id::text || ':' ||
                          coalesce(nullable_metric::text, '<NULL>') || ':' ||
                          coalesce(payload, '<NULL>'), ',' ORDER BY id))
    FROM pgstrom_mvp_small
    WHERE id BETWEEN 1 AND 16;"
mixed_uniform_signature="
    SELECT count(*) || '|' || coalesce(sum(id)::text,'') || '|' ||
           coalesce(sum(amount)::text,'') || '|' ||
           md5(string_agg(id::text || ':' || payload, ',' ORDER BY id))
    FROM pgstrom_mvp_heap
    WHERE grp BETWEEN 101 AND 207
      AND amount >= 500.00
      AND payload ~ '^[0-7]';"
mixed_skew_signature="
    SELECT count(*) || '|' || coalesce(sum(id)::text,'') || '|' ||
           coalesce(sum(metric)::text,'') || '|' ||
           count(*) FILTER (WHERE payload IS NULL) || '|' ||
           md5(string_agg(id::text || ':' || coalesce(payload, '<NULL>'),
                          ',' ORDER BY id))
    FROM pgstrom_mvp_skew
    WHERE metric BETWEEN -500 AND 750
      AND amount >= -250.00
      AND (payload IS NULL OR payload ~ '^[0-7]');"
mixed_small_signature="
    SELECT count(*) || '|' || coalesce(sum(id)::text,'') || '|' ||
           count(*) FILTER (WHERE payload IS NULL) || '|' ||
           md5(string_agg(id::text || ':' || coalesce(payload, '<NULL>'),
                          ',' ORDER BY id))
    FROM pgstrom_mvp_small
    WHERE id BETWEEN 1 AND 16
      AND (payload IS NULL OR payload ~ '^[0-7]');"

require_gpuscan_plan "uniform heap signature" "$uniform_signature"
require_gpuscan_plan "skew heap signature" "$skew_signature"
require_gpuscan_plan "small heap signature" "$small_signature"

compare_signature "uniform heap" "$uniform_signature"
compare_signature "skew heap" "$skew_signature"
compare_signature "small heap" "$small_signature"

require_mixed_quals_plan "uniform heap" "$mixed_uniform_signature"
require_mixed_quals_plan "skew heap" "$mixed_skew_signature"
require_mixed_quals_plan "small heap" "$mixed_small_signature"

compare_signature "mixed-quals uniform heap" "$mixed_uniform_signature" "$mixed_gpu_settings"
compare_signature "mixed-quals skew heap" "$mixed_skew_signature" "$mixed_gpu_settings"
compare_signature "mixed-quals small heap" "$mixed_small_signature" "$mixed_gpu_settings"

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
    "SELECT * FROM pgstrom_mvp_heap WHERE payload ~ '^[0-9a-f]{8}'" \
    "SELECT * FROM pgstrom_mvp_heap WHERE grp=42 AND payload ~ '^[0-9a-f]{8}'"
do
    fallback_plan=$("${psql_cmd[@]}" -Atqc "
        SET optimizer=off;
        SET pg_strom.enabled=on;
        SET pg_strom.enable_gpuscan=on;
        SET pg_strom.enable_gpupreagg=off;
        SET pg_strom.cloudberry_enable_host_quals=off;
        SET enable_seqscan=off;
        EXPLAIN $fallback_case;")
    if grep -q 'GpuScan' <<<"$fallback_plan"; then
        echo "unsupported case unexpectedly produced a GpuScan: $fallback_case" >&2
        exit 1
    fi
done

host_only_plan=$("${psql_cmd[@]}" -Atqc "
    $mixed_gpu_settings
    EXPLAIN SELECT * FROM pgstrom_mvp_heap
    WHERE payload ~ '^[0-9a-f]{8}';")
if grep -q 'GpuScan' <<<"$host_only_plan"; then
    echo 'pure host-only quals unexpectedly produced a GpuScan with mixed quals enabled' >&2
    exit 1
fi

echo "Multi-segment GpuScan plans and CPU/GPU signatures passed on $primary_segment_count primaries."
echo "Each device-only and mixed-quals signature passed $repeat_count GPU iterations; unsupported cases retained native plans."
