#!/usr/bin/env bash
# GPU-free checks only. Real planner/executor acceptance is a separate runner.
set -euo pipefail
test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d /tmp/pgstrom-development-check.XXXXXX)
trap 'rm -rf "$work"' EXIT
bash "$test_dir/test_static_mvp.sh"
python3 "$test_dir/test_operator_static.py"
python3 "$test_dir/test_gpujoin.py"
python3 "$test_dir/test_gpusort.py"
bash -n "$test_dir/check_gpujoin_host_syntax.sh"
for script in "$test_dir"/demo/*.sh; do bash -n "$script"; done
python3 - "$test_dir/demo/run_development_regression.py" <<'PY'
import ast
import pathlib
import sys
ast.parse(pathlib.Path(sys.argv[1]).read_text(), filename=sys.argv[1])
print("Development Python syntax: PASS")
PY
"${CC:-cc}" -std=c99 -Wall -Wextra -Werror \
    "$test_dir/test_budget_queue.c" -o "$work/test_budget_queue"
"$work/test_budget_queue"
"${CC:-cc}" -std=c99 -Wall -Wextra -Werror \
    "$test_dir/test_sort_policy.c" -o "$work/test_sort_policy"
"$work/test_sort_policy"
git -C "$test_dir" diff --check
printf '%s\n' 'GPU-free development checks passed; GPU acceptance remains pending.'
