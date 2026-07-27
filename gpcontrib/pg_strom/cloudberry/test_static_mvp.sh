#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
gpu_scan="$repo_root/gpcontrib/pg_strom/src/gpu_scan.c"
cdbplan="$repo_root/src/backend/cdb/cdbplan.c"
makefile="$repo_root/gpcontrib/pg_strom/src/Makefile"
main_c="$repo_root/gpcontrib/pg_strom/src/main.c"
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
require_text '!allow_host_quals && pp_info->host_quals != NIL' "$gpu_scan"
require_text 'MUTATE\(newcscan->custom_plans' "$cdbplan"
require_text 'MUTATE\(newcscan->custom_exprs' "$cdbplan"
require_text 'MUTATE\(newcscan->custom_scan_tlist' "$cdbplan"
if grep -A18 'case T_CustomScan:' "$cdbplan" | grep -q 'MUTATE.*custom_private'; then
    echo 'custom_private must remain opaque to the CustomScan mutator' >&2
    exit 1
fi
require_text 'PGSTROM_WITH_ARROW.*\?= 1' "$makefile"
require_text '#ifndef GP_VERSION_NUM' "$main_c"
require_text 'Motion .*slice\[1-9\].*segments: 1' "$demo_runner"

echo 'Cloudberry PG-Strom MVP static checks: PASS'
