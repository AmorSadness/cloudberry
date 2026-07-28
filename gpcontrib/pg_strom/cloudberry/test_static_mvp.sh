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
require_text 'Motion .*slice\[1-9\].*segments: 1' "$demo_runner"

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
