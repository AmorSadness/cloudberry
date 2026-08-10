#!/usr/bin/env bash
set -euo pipefail

demo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

export PGSTROM_MVP_TEST_OPERATOR=gpupreagg
export PGSTROM_MVP_CANCEL_CYCLES="${PGSTROM_GPUPREAGG_CANCEL_CYCLES:-${PGSTROM_MVP_CANCEL_CYCLES:-3}}"
export PGSTROM_MVP_CANCEL_TIMEOUT="${PGSTROM_GPUPREAGG_CANCEL_TIMEOUT:-${PGSTROM_MVP_CANCEL_TIMEOUT:-30}}"

exec "$demo_dir/run_query_cancel.sh"
