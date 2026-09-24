# Cloudberry integration: next development baseline

Status: source development; **GPU acceptance pending**. This work is developed
without a GPU. Historical 2026-08-14 acceptance does not validate these changes.
The supported validation topology remains one host, at least two Primaries,
one shared GPU, one UID and one PID namespace, PostgreSQL planner.

## Colocated GpuJoin development (2026-09-24)

A default-off `pg_strom.enable_gpujoin` now enables a restricted two-table
colocated INNER hash join. Full same-type integer distribution keys, identical
hash opclasses/key order/Segment counts and ordinary heap storage are required.
The inner input is a native serial QE Seq Scan; no input Motion, replicated,
partition, outer/semi/anti join or Join+PreAgg fusion is admitted. Predicate-free
fused join input does not enable standalone predicate-free GpuScan.
`pg_strom.cloudberry_gpujoin_max_inner_size` defaults to 256MB per QE; estimates
above it retain native paths and actual preload overflow fails explicitly.

Source/API syntax and GPU-free checks passed; **all GPU runtime acceptance is
pending**. See `CLOUDBERRY_GPUJOIN_COLOCATED_DESIGN.md` for the implementation,
manual GPU runner, shared-buffer lifecycle and remaining failure/recovery gates.
The development suite now includes `run_gpujoin_regression.py`; its default
run does not execute destructive Service tests or allocation injection.

## Ordered implementation

1. Mixed-input reliability: dedicated cancellation/recovery/concurrency and
   post-reservation failure mode; ROW input, NULL/empty, dropped/unreferenced
   missing columns and repeated generic prepared executions.
2. Current capability documentation and one regression entry point, with
   source revision/diff, database/extension/Service metadata and plan artifacts.
3. FIFO allocation admission, bounded waiting, disconnect/shutdown cleanup,
   dead-Service queue reclamation. This is allocation fairness, not resource
   group scheduling or whole-query admission.
4. Opt-in integer/float AVG and device-executable aggregate FILTER.
5. Opt-in predicate-free aggregate input, leaving standalone GpuScan eligibility
   and host-only predicate fallback unchanged.
6. Opt-in Redistribute by grouping keys + CPU final alongside Gather-final.
7. Operator foundations, in order: more scalar COUNT inputs, native CPU input
   for host-only WHERE, CPU-only aggregate FILTER, and distributed heap partitions.

New SQL capabilities are experimental and independently off by default. The
extension SQL catalog remains 6.3; the upstream source snapshot remains 6.1.
Neither version alone identifies the Cloudberry source changes; retain the
suite revision and diff when recording acceptance.

This baseline does not add ORCA, AO/AOCO, replicated table acceleration or
direct GPU partition scans. Heap partitions use **native CPU scanning/pruning
followed by GPU partial aggregation**, not per-partition GpuScan or partitionwise
final aggregation. Numeric arithmetic aggregates, DISTINCT, arrays/composites
as COUNT inputs, and grouping sets retain native plans.

| Switch | Default | New scope |
| --- | --- | --- |
| `pg_strom.cloudberry_enable_extended_agg` | off | AVG on int2/int4/int8/float4/float8; device-executable FILTER on the supported aggregate whitelist, including HAVING |
| `pg_strom.cloudberry_enable_unfiltered_agg` | off | Predicate-free GpuPreAgg input; standalone scans and host-only predicates retain native eligibility |
| `pg_strom.cloudberry_enable_redistribute_final` | off | Non-colocated grouped partials may Redistribute to per-QE CPU final; Gather remains a competing candidate |
| `pg_strom.cloudberry_enable_count_types` | off | COUNT of additional device-supported base scalar types; no arrays, domains, composites or unsupported device types |
| `pg_strom.cloudberry_enable_host_input` | off | Pure host-only WHERE using native CPU scan + ROW KDS + GpuPreAgg; standalone scans stay native |
| `pg_strom.cloudberry_enable_cpu_filter` | off | CPU-only aggregate FILTER, with per-aggregate conditional argument projection; AVG still requires extended_agg |
| `pg_strom.cloudberry_enable_heap_partition` | off | Native heap Append/pruning below GpuPreAgg; all descendants must have compatible distributed heap storage |

All require `pg_strom.enable_gpupreagg=on` and `optimizer=off`. Mixed WHERE
also requires `pg_strom.cloudberry_enable_host_quals=on`. FILTER is applied to
each aggregate's partial input, not promoted to a scan predicate; FALSE/UNKNOWN
must leave the group present with zero/NULL states as appropriate. AVG reuses
the upstream count+sum partial states and CPU final functions, not an average
of per-Segment averages. The integer AVG result may be numeric even though
numeric **input arithmetic** aggregates remain excluded (COUNT is separate).

## Operator foundation semantics

COUNT adds device-supported scalar inputs such as bool, text/varchar/bpchar,
bytea, numeric, date/time/timetz/timestamp/timestamptz/interval, uuid, inet,
macaddr and jsonb. Eligibility still checks the actual device type and input
expression; this is not arbitrary PostgreSQL type support. SUM/MIN/MAX/AVG do
not inherit COUNT's expanded whitelist. Device representation limits still
apply, including numeric range; this change does not implement arbitrary
precision device arithmetic. Empty input and NULL handling use the existing
int8 partial COUNT state and CPU final function.

Native CPU input is an additional costed candidate. It keeps native WHERE,
MVCC and partition column mapping; it projects only the aggregate inputs and
grouping keys into a self-contained ROW KDS. Varlena values are detoasted before
serialization. Code generation loads source **target positions**, not physical
heap attribute numbers. EXPLAIN reports `Native CPU scan/filter/projection rows`
under `Pre-Aggregation Input`, distinguishable from the existing mixed GpuScan
path. Native scan/projection costs and projected transfer width are charged;
no performance improvement is asserted without measurement.

CPU FILTER stays attached to each aggregate, never becomes a WHERE condition.
For filtered arguments CPU projects `CASE WHEN filter THEN argument ELSE NULL
END` (including the partial function's cast) and a boolean filter value. This
preserves false/unknown groups, COUNT(*) and argument short-circuiting. Filters
can be evaluated more than once in these projections; volatile expressions
and subplans in the native input query are conservatively rejected. Aggregate
arguments and grouping expressions still require the established device
expression/type eligibility. HAVING runs after cross-Segment final aggregation.

Feature gates compose: predicate-free input still needs `unfiltered_agg`;
pure host WHERE needs `host_input`; mixed host/device WHERE retains the
`host_quals` opt-in; a CPU-only FILTER needs `cpu_filter`; a partition parent
needs `heap_partition`. No single new switch silently enables all these paths.
The original fused GPU candidates remain available when eligible.

Partition support covers declarative distributed heap trees, including default
and nested partitions and attached leaves with different physical column order.
Every descendant is checked, even if currently pruned. Distribution policies
must match by column names, opclasses and Segment count. Native Append owns
static/runtime pruning; its actual locus is used to decide local versus
cross-Segment final aggregation. AO/AOCO/foreign or replicated descendants,
traditional inheritance, parameterized inputs, parallel-worker/Motion-bearing
source paths and unsupported native source node kinds are rejected. Final
aggregation is above the combined native input, not independently finalized
on each leaf.

Redistribute uses the actual partial target's grouping sortrefs and Cloudberry's
`choose_grouping_locus()`, and declines the candidate if no valid hashed locus
can be formed. Motion and CPU final own their costs, with global final group
estimates divided among destination QEs. Global aggregates still Gather;
colocated grouping keeps local-final. The existing non-colocated 50% partial-row
reduction guard remains. No cost calibration or scaling claim is made.

## FIFO ledger and upgrade

The queue has 1024 allocation waiter slots across the existing 128 Service
owners. It serializes admission by ticket, including pool allocation and full
replacement-buffer peaks. An impossible request is rejected immediately.
`shared_gpu_budget_timeout=0` remains nonblocking; positive values bound FIFO
waiting. The original client socket is polled for disconnect during both
OpenSession (monitor thread) and worker allocation. Timeout, disconnect and
shutdown remove the ticket; dead-Service reclamation removes all its tickets.
Queue exhaustion is an explicit rejection, not a FIFO bypass.

This can cause head-of-line waiting. Queries that already hold buffers can
still time out while requesting more memory; FIFO is not a whole-query resource
reservation and does not promise deadlock-free completion or resource-group
fairness. External CUDA allocations remain outside the budget.

**Shared ledger protocol changes from 1 to 2.** Its POSIX name deliberately
stays `/pgstrom-gpu-budget-<uid>-<normalized-gpu-uuid>`. Mixed binaries fail the
size/version check instead of creating independent ledgers and double-spending
GPU memory. Before installing this build, stop **all** Services sharing that
UID/GPU (including other clusters). After confirming those processes have exited,
remove only the matching old object under `/dev/shm`, then start all instances
with the same new binary. Do not clear a live ledger or use a wildcard cleanup.
Downgrade requires the same all-Services-stopped procedure. The SQL catalog can
stay at 6.3 because the view/function signatures did not change.

## Manual GPU acceptance

Build and install with the target Cloudberry pg_config and PGSTROM_WITH_ARROW=0
on all instances. Restart with the matching device sources/fatbin and run the
existing demo setup on a dedicated acceptance database. The suite's run_demo
recreates the shared demo tables. The runners modify
their dedicated fixture tables; do not use a production database.

```bash
PGDATABASE=pgstrom_mvp bash cloudberry/demo/run_development_suite.sh
# Just the four new operator groups (also included in --stage all / suite):
PGDATABASE=pgstrom_mvp python3 cloudberry/demo/run_development_regression.py --stage operators
# Individual stages: count_types, host_input, cpu_filter, heap_partition
# Explicit disruptive Service restart acceptance (local target only):
PGDATABASE=pgstrom_mvp PGSTROM_GPUPREAGG_MIXED_RELIABILITY=1 \
  PGSTROM_GPUPREAGG_ALLOW_SERVICE_RESTART=1 \
  bash cloudberry/demo/run_gpupreagg_failure_recovery.sh
# Crash recovery also requires the second explicit opt-in:
PGDATABASE=pgstrom_mvp PGSTROM_GPUPREAGG_MIXED_RELIABILITY=1 \
  PGSTROM_GPUPREAGG_ALLOW_SERVICE_RESTART=1 \
  PGSTROM_GPUPREAGG_ALLOW_HARD_FAILURE=1 PGSTROM_GPUPREAGG_SERVICE_SIGNAL=KILL \
  bash cloudberry/demo/run_gpupreagg_failure_recovery.sh
```

Additional acceptance gates:

```bash
# Expansion failure (superuser; creates a 2M-row fixture):
PGDATABASE=pgstrom_mvp python3 cloudberry/demo/run_development_regression.py \
  --stage mixed --expansion-failure
# Correlated rescan: requires Actual Loops > 1, not merely identical results:
PGDATABASE=pgstrom_mvp python3 cloudberry/demo/run_development_regression.py \
  --stage mixed --rescan
# Configure the isolated cluster's budget and positive admission timeout first,
# uniformly on all Services. No waiting fails this gate.
PGDATABASE=pgstrom_mvp PGSTROM_SHARED_BUDGET_FAIRNESS=1 \
  PGSTROM_SHARED_BUDGET_CLIENTS=24 PGSTROM_SHARED_BUDGET_TIMEOUT=120 \
  bash cloudberry/demo/run_shared_gpu_budget.sh
```

Paths above are relative to gpcontrib/pg_strom. The Python runner needs Python 3
and psql only; it creates a uniquely named schema and removes only that schema.
It saves EXPLAIN ANALYZE JSON and results under a unique /tmp directory, including
on failure. A native fallback does not satisfy a GPU-positive case. Its default
mode exposes valid paths using planner settings and makes no performance claim.
Run `--normal-planner` separately to assess ordinary cost-based selection.

AVG checks include unequal per-QE group populations, integer extrema,
NULL/empty inputs, and NaN/infinities. Integer-valued float cases compare exact
serialized results. The fractional float case compares finite averages with
relative tolerance `1e-10` and absolute tolerance `1e-12`; NULL/special values
and all other columns must match. That tolerance is an explicit test oracle,
not a promise of bitwise equality across CPU/GPU summation orders.
The mixed concurrency invocation in the suite supplies correctness-only
PGOPTIONS; its default baseline invocation retains normal costs. Neither a
forced plan nor the FIFO pressure test is a throughput benchmark.

The existing superuser-only `shared_gpu_budget_inject_oom_segments(gpu_id,count)`
now accepts `count=-1` for one failure after reserving an expanded final buffer.
Positive counts retain their initial-query-buffer meaning; zero disarms either
mode. Run this only on an otherwise idle acceptance cluster, since it is scoped
to a Service/device, not to one SQL session. The expansion runner always disarms
remaining injections in its cleanup. It requires the exact injected error and
no partial output; an ordinary budget rejection is not expansion-hook evidence.

Suite flags `PGSTROM_DEVELOPMENT_EXPANSION_FAILURE=1`,
`PGSTROM_DEVELOPMENT_RESCAN=1`, and `PGSTROM_SHARED_BUDGET_FAIRNESS=1` include
these additional gates. Omitted gates are written as `.SKIPPED` artifacts;
`SELECTED_CASES_PASSED` never means that omitted fault/pressure gates passed.

## GPU-free checks performed during development

`bash cloudberry/test_development.sh` runs the historical static guards, shell
and Python syntax checks, operator source-contract checks, and the actual FIFO
header's CPU invariant tests
(order, admission arithmetic/overflow, cancellation removal, owner cleanup,
capacity and ticket wrap). The changed planner, code-generation and executor C
files were additionally syntax checked against installed Cloudberry server
headers with temporary opaque CUDA
declarations. That check validates planner APIs/C syntax only; it is not an SDK
build. This environment has no CUDA toolkit headers/nvcc, so a full extension
and device build remains part of the target-environment handoff.

The operator runner includes type/NULL/empty-input matrices, TOAST and multi-chunk
ROW input on the dual-Primary topology, missing/dropped columns, independent
FILTER/HAVING predicates, division-by-zero short-circuit/error recovery,
volatile/subplan rejection, static/generic-plan pruning, nested/default
partitions, reordered attached columns, and non-heap/inheritance/ORCA fallback.
Positive cases require actual GpuPreAgg plans with CPU fallback disabled and
repeat CPU/GPU result comparisons; merely retaining a native plan is a failure.
Source-contract checks only ensure guard and case presence, not runtime behavior.

## Remaining acceptance gates

All new GPU runtime cases, concurrent FIFO progress under real memory pressure,
replacement-buffer expansion failure, Service crash queue reclamation, and
prepared/rescan behavior must be executed in the target environment. A static
PASS or a successful host build does not close these gates. Do not relabel this
document as accepted until logs for each enabled feature and failure mode exist.
