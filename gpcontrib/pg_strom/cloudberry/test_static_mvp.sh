#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
gpu_scan="$repo_root/gpcontrib/pg_strom/src/gpu_scan.c"
gpu_cache="$repo_root/gpcontrib/pg_strom/src/gpu_cache.c"
cdbplan="$repo_root/src/backend/cdb/cdbplan.c"
makefile="$repo_root/gpcontrib/pg_strom/src/Makefile"
main_c="$repo_root/gpcontrib/pg_strom/src/main.c"
gpu_service="$repo_root/gpcontrib/pg_strom/src/gpu_service.c"
demo_runner="$repo_root/gpcontrib/pg_strom/cloudberry/demo/run_demo.sh"
failure_runner="$repo_root/gpcontrib/pg_strom/cloudberry/demo/run_failure_recovery.sh"
cancel_runner="$repo_root/gpcontrib/pg_strom/cloudberry/demo/run_query_cancel.sh"
upgrade_sql="$repo_root/gpcontrib/pg_strom/src/sql/pg_strom--6.0--6.1.sql"
demo_config="$repo_root/gpcontrib/pg_strom/cloudberry/demo/postgresql.conf.mvp"
demo_setup="$repo_root/gpcontrib/pg_strom/cloudberry/demo/setup.sql"
demo_verify="$repo_root/gpcontrib/pg_strom/cloudberry/demo/verify.sql"
demo_readme="$repo_root/gpcontrib/pg_strom/cloudberry/demo/README.md"

require_text() {
    local pattern=$1
    local file=$2
    if ! grep -Eq "$pattern" "$file"; then
        echo "missing expected MVP guard: $pattern in $file" >&2
        exit 1
    fi
}

require_text 'cdbpathlocus_from_baserel' "$gpu_scan"
require_text 'const CustomScan \*cscan = \(const CustomScan \*\)plan' "$gpu_scan"
require_text 'planner_segment_count\(baserel->cdbpolicy\)' "$gpu_scan"
require_text 'disk_cost = .*baserel->pages / segment_divisor' "$gpu_scan"
require_text 'path\.rescannable = true' "$gpu_scan"
require_text 'path\.sameslice_relids = baserel->relids' "$gpu_scan"
require_text 'GpPolicyIsPartitioned\(baserel->cdbpolicy\)' "$gpu_scan"
require_text 'if \(optimizer\)' "$gpu_scan"
require_text 'baserel->reloptkind == RELOPT_OTHER_MEMBER_REL' "$gpu_scan"
require_text '!allow_host_quals && pp_info->host_quals != NIL' "$gpu_scan"
require_text 'MUTATE\(newcscan->custom_plans' "$cdbplan"
require_text 'MUTATE\(newcscan->custom_exprs' "$cdbplan"
require_text 'MUTATE\(newcscan->custom_scan_tlist' "$cdbplan"
if grep -A18 'case T_CustomScan:' "$cdbplan" | grep -q 'MUTATE.*custom_private'; then
    echo 'custom_private must remain opaque to the CustomScan mutator' >&2
    exit 1
fi
require_text 'PGSTROM_WITH_ARROW.*\?= 1' "$makefile"
require_text 'GENERATED-HEADERS.*pgstrom_device_config\.h' "$makefile"
require_text 'PGSTROM_DEVICE_BLCKSZ.*BLCKSZ' "$repo_root/gpcontrib/pg_strom/src/Makefile.cuda"
require_text 'PGSTROM_DEVICE_RELSEG_SIZE.*RELSEG_SIZE' "$repo_root/gpcontrib/pg_strom/src/Makefile.cuda"
require_text 'PGSTROM_DEVICE_PAGE_LAYOUT_VERSION.*PG_PAGE_LAYOUT_VERSION' "$repo_root/gpcontrib/pg_strom/src/Makefile.cuda"
require_text '__CUDA_CORE_HEADERS = pgstrom_device_config\.h' "$repo_root/gpcontrib/pg_strom/src/Makefile.cuda"
require_text 'CUDA_BUILD_CONFIG = NAMEDATALEN=.*BLCKSZ=.*RELSEG_SIZE=.*PG_PAGE_LAYOUT_VERSION=.*MAXIMUM_ALIGNOF=' "$repo_root/gpcontrib/pg_strom/src/Makefile.cuda"
require_text '#include "pgstrom_device_config\.h"' "$repo_root/gpcontrib/pg_strom/src/xpu_common.h"
require_text '#define BLCKSZ.*PGSTROM_DEVICE_BLCKSZ' "$repo_root/gpcontrib/pg_strom/src/xpu_common.h"
require_text 'Must match CUDA_BUILD_CONFIG in Makefile\.cuda exactly' "$gpu_service"
if grep -Eq '^#define BLCKSZ[[:space:]]+8192' \
    "$repo_root/gpcontrib/pg_strom/src/xpu_common.h"; then
    echo 'device BLCKSZ must come from the target server configuration' >&2
    exit 1
fi
require_text '#ifndef GP_VERSION_NUM' "$main_c"
require_text 'pgstromGpuCacheIsInitialized\(\) &&' "$gpu_scan"
require_text 'pgstromGpuCacheIsInitialized\(void\)' "$gpu_cache"
require_text '!pgstrom_enable_gpucache \|\| !pgstromGpuCacheIsInitialized\(\)' "$gpu_cache"
require_text 'has_gpucache = !pgstromGpuCacheIsInitialized\(\)' "$gpu_service"
require_text 'pgstromGpuCacheIsInitialized\(\) && !has_gpucache' "$gpu_service"
require_text 'if \(pgstromGpuCacheIsInitialized\(\)\)' "$gpu_service"
require_text '__gpuContextStartWorkers\(void\)' "$gpu_service"
require_text '__gpuContextStartWorkers\(\);' "$gpu_service"
require_text 'unable to start GPU%d worker pool' "$gpu_service"
require_text 'gpuserv_shared_state->gpuserv_ready_accept = false;' "$gpu_service"
require_text 'pgstrom_gpu_service_status\(PG_FUNCTION_ARGS\)' "$gpu_service"
require_text 'service_generation' "$gpu_service"
require_text 'submitted_commands' "$gpu_service"
require_text 'cancelled_commands' "$gpu_service"
require_text 'actual_workers' "$gpu_service"
require_text "default_version = '6\.1'" "$repo_root/gpcontrib/pg_strom/src/pg_strom.control"
require_text 'pg_strom--6\.0--6\.1\.sql' "$makefile"
require_text 'gpu_service_status_local' "$upgrade_sql"
require_text 'EXECUTE ON COORDINATOR' "$upgrade_sql"
require_text 'gpu_service_status_segments' "$upgrade_sql"
require_text 'EXECUTE ON ALL SEGMENTS' "$upgrade_sql"
require_text 'CREATE VIEW pgstrom\.gpu_service_status' "$upgrade_sql"
require_text 'gp_segment_configuration' "$demo_runner"
require_text 'primary_segment_count < 2' "$demo_runner"
require_text 'segments: \$\{primary_segment_count\}' "$demo_runner"
require_text 'PGSTROM_MVP_REPEAT' "$demo_runner"
require_text 'require_distribution_shape "uniform heap" pgstrom_mvp_heap' "$demo_runner"
require_text 'require_distribution_shape "skew heap" pgstrom_mvp_skew 1' "$demo_runner"
require_text 'require_distribution_shape "small heap" pgstrom_mvp_small 1' "$demo_runner"
require_text 'compare_signature "uniform heap"' "$demo_runner"
require_text 'compare_signature "skew heap"' "$demo_runner"
require_text 'compare_signature "small heap"' "$demo_runner"
require_text 'pgstrom\.gpu_service_status' "$demo_runner"
require_text 'actual_workers = configured_workers' "$demo_runner"
require_text "gpu_mempool_segment_sz = '256MB'" "$demo_config"
require_text 'gpu_mempool_max_ratio = 0\.20' "$demo_config"
require_text 'CREATE TABLE pgstrom_mvp_skew' "$demo_setup"
require_text 'CREATE TABLE pgstrom_mvp_small' "$demo_setup"
require_text 'DISTRIBUTED BY \(dist_key\)' "$demo_setup"
require_text 'EXPLAIN \(ANALYZE, VERBOSE, COSTS OFF\)' "$demo_verify"
require_text 'with-blocksize=32' "$demo_readme"
require_text 'with-wal-blocksize=32' "$demo_readme"
require_text 'PG_CONFIG="\$\(command -v pg_config\)"' "$demo_readme"
require_text 'PG_CONFIG="\$PG_CONFIG"' "$demo_readme"
require_text 'NUM_PRIMARY_MIRROR_PAIRS=2' "$demo_readme"
require_text 'WITH_MIRRORS=false' "$demo_readme"
require_text 'shared_preload_libraries=pg_strom' "$demo_readme"
require_text 'query must return .*2\|2' "$demo_readme"
require_text 'PGSTROM_MVP_ALLOW_SERVICE_RESTART' "$failure_runner"
require_text 'PGSTROM_MVP_TARGET_CONTENT' "$failure_runner"
require_text 'PGSTROM_MVP_RECOVERY_CYCLES' "$failure_runner"
require_text 'PGSTROM_MVP_SERVICE_SIGNAL' "$failure_runner"
require_text 'PGSTROM_MVP_ALLOW_HARD_FAILURE' "$failure_runner"
require_text 'kill -"\$service_signal" "\$old_service_pid"' "$failure_runner"
require_text 'UNEXPECTED_PARTIAL_RESULT' "$failure_runner"
require_text 'find_gpu_service_pid' "$failure_runner"
require_text 'worker_log_count' "$failure_runner"
require_text 'new_service_pid=.*wait_for_new_service' "$failure_runner"
require_text 'recovered_signature != "\$cpu_signature"' "$failure_runner"
require_text 'service_generation' "$failure_runner"
require_text 'PGSTROM_MVP_CANCEL_CYCLES' "$cancel_runner"
require_text 'pg_cancel_backend\(\$backend_pid\)' "$cancel_runner"
require_text 'pgstrom_mvp_cancel_target' "$cancel_runner"
require_text 'SET enable_material=off' "$cancel_runner"
require_text "grep -q 'Materialize'" "$cancel_runner"
require_text 'submitted > old_submitted' "$cancel_runner"
require_text 'acceptance cluster is not idle at baseline' "$cancel_runner"
require_text 'terminal_delta < submitted_delta' "$cancel_runner"
require_text 'queued == 0 && active == 0 && clients == 0' "$cancel_runner"
require_text 'run_failure_recovery\.sh' "$demo_readme"
require_text 'run_query_cancel\.sh' "$demo_readme"
if grep -Eq 'segments: 1([^0-9]|$)' "$demo_runner"; then
    echo 'multi-segment demo must not hard-code a single QE segment' >&2
    exit 1
fi

initial_workers_line=$(grep -n '__gpuContextStartWorkers();' "$gpu_service" |
    cut -d: -f1)
ready_line=$(grep -n 'gpuserv_shared_state->gpuserv_ready_accept = true;' "$gpu_service" |
    cut -d: -f1)
if [[ -z "$initial_workers_line" || -z "$ready_line" ||
      "$initial_workers_line" -ge "$ready_line" ]]; then
    echo 'GPU Service must start workers before advertising readiness' >&2
    exit 1
fi

echo 'Cloudberry PG-Strom MVP static checks: PASS'
