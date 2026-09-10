#!/usr/bin/env bash
set -euo pipefail
demo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -n ${PGSTROM_SUITE_RESULTS:-} ]]; then
    mkdir -- "$PGSTROM_SUITE_RESULTS" # refuse to overwrite/reuse old PASS artifacts
    results=$(cd "$PGSTROM_SUITE_RESULTS" && pwd)
else
    results=$(mktemp -d /tmp/pgstrom-suite.XXXXXX)
fi
repo_root=$(git -C "$demo_dir" rev-parse --show-toplevel)
trap 'printf "Suite artifacts: %s\n" "$results" >&2' EXIT
git -C "$demo_dir" rev-parse HEAD >"$results/source-revision.txt"
git -C "$repo_root" diff --binary -- gpcontrib/pg_strom src/backend/cdb/cdbplan.c >"$results/source-changes.patch"
(
    cd "$repo_root"
    # Hash the active integration sources, not the vendored deadcode/submodule links.
    git ls-files -co --exclude-standard -z -- gpcontrib/pg_strom/src \
        gpcontrib/pg_strom/cloudberry gpcontrib/pg_strom/Makefile.common \
        'gpcontrib/pg_strom/CLOUDBERRY*' src/backend/cdb/cdbplan.c \
        | xargs -0 sha256sum
) >"$results/source-sha256.txt"
# Historical runners explicitly test the pre-development feature boundary.
export PGOPTIONS="${PGOPTIONS:-} -c pg_strom.cloudberry_enable_extended_agg=off -c pg_strom.cloudberry_enable_unfiltered_agg=off -c pg_strom.cloudberry_enable_redistribute_final=off -c pg_strom.cloudberry_enable_count_types=off -c pg_strom.cloudberry_enable_host_input=off -c pg_strom.cloudberry_enable_cpu_filter=off -c pg_strom.cloudberry_enable_heap_partition=off"

run() {
    local label=$1
    shift
    "$@" 2>&1 | tee "$results/$label.log"
}

# run_demo recreates the dedicated demo fixtures; use an acceptance database.
for runner in run_demo run_gpupreagg_mvp run_gpupreagg_m4b run_gpupreagg_m5a \
              run_gpupreagg_having run_gpupreagg_mixed_quals; do
    run "$runner" bash "$demo_dir/$runner.sh"
done
run development env PGSTROM_RESULTS="$results/development-artifacts" \
    python3 "$demo_dir/run_development_regression.py" --stage all
if [[ ${PGSTROM_DEVELOPMENT_EXPANSION_FAILURE:-0} == 1 ]]; then
    run expansion env PGSTROM_RESULTS="$results/expansion-artifacts" \
        python3 "$demo_dir/run_development_regression.py" --stage mixed --expansion-failure
else
    printf '%s\n' 'SKIP expansion failure: PGSTROM_DEVELOPMENT_EXPANSION_FAILURE=1 required' \
        | tee "$results/expansion.SKIPPED"
fi
if [[ ${PGSTROM_DEVELOPMENT_RESCAN:-0} == 1 ]]; then
    run rescan env PGSTROM_RESULTS="$results/rescan-artifacts" \
        python3 "$demo_dir/run_development_regression.py" --stage mixed --rescan
else
    printf '%s\n' 'SKIP rescan: PGSTROM_DEVELOPMENT_RESCAN=1 required' \
        | tee "$results/rescan.SKIPPED"
fi
if [[ ${PGSTROM_SHARED_BUDGET_FAIRNESS:-0} == 1 ]]; then
    run fifo_pressure bash "$demo_dir/run_shared_gpu_budget.sh"
else
    printf '%s\n' 'SKIP FIFO pressure: tune admission budget, then set PGSTROM_SHARED_BUDGET_FAIRNESS=1' \
        | tee "$results/fifo.SKIPPED"
fi
run concurrency bash "$demo_dir/run_shared_gpu_concurrency_matrix.sh"
run mixed_concurrency env PGSTROM_GPUPREAGG_MIXED_RELIABILITY=1 \
    PGOPTIONS="${PGOPTIONS:-} -c gp_enable_multiphase_agg=off -c enable_seqscan=off -c pg_strom.gpu_setup_cost=0 -c pg_strom.gpu_tuple_cost=0 -c pg_strom.gpu_operator_cost=0" \
    bash "$demo_dir/run_shared_gpu_concurrency_matrix.sh"
run mixed_cancel env PGSTROM_GPUPREAGG_MIXED_RELIABILITY=1 \
    bash "$demo_dir/run_gpupreagg_cancel.sh"

# Preserve the established two explicit fault-test opt-ins. Never enable them here.
if [[ ${PGSTROM_GPUPREAGG_ALLOW_SERVICE_RESTART:-0} == 1 ]]; then
    run mixed_recovery env PGSTROM_GPUPREAGG_MIXED_RELIABILITY=1 \
        bash "$demo_dir/run_gpupreagg_failure_recovery.sh"
else
    printf '%s\n' 'SKIP Service failure recovery: explicit restart opt-in absent' \
        | tee "$results/recovery.SKIPPED"
fi
printf '%s\n' 'Selected GPU suite cases passed; inspect *.SKIPPED for omitted tests.' \
    | tee "$results/SELECTED_CASES_PASSED"
