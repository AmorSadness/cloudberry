# PG-Strom v6.1 Cloudberry GpuScan MVP

This directory is a complete source snapshot of PG-Strom v6.1 from upstream
commit `4d12ef415759dc48cd4c1421565e9c694b7bd3f9`:

<https://github.com/heterodb/pg-strom/tree/4d12ef415759dc48cd4c1421565e9c694b7bd3f9>

The upstream PostgreSQL License is preserved in `LICENSE`.  The snapshot is
kept outside Cloudberry's default build and is built explicitly with the
Cloudberry `pg_config`:

```sh
make -C gpcontrib/pg_strom/src \
  PG_CONFIG=/path/to/cloudberry/bin/pg_config \
  PGSTROM_WITH_ARROW=0
make -C gpcontrib/pg_strom/src \
  PG_CONFIG=/path/to/cloudberry/bin/pg_config \
  PGSTROM_WITH_ARROW=0 install
```

`PGSTROM_WITH_ARROW` accepts only `0` or `1`.  The MVP requires `0`; this
prevents a locally installed Arrow or Parquet package from changing the link
dependencies.  HeteroDB Extra is loaded dynamically when available and is not
a build or runtime requirement for the non-GPU-Direct GpuScan MVP.

## Supported scope

The Cloudberry build registers GpuScan (plus its GPU Service) and a default-off
experimental Gather-only GpuPreAgg path.  Both are restricted to a
non-partitioned, ordinarily distributed heap table.  AO, AOCO, partitioned
tables, foreign/Arrow tables and coordinator-local or replicated tables retain
native paths.  GpuJoin, GpuCache, BRIN acceleration, SELECT-INTO-Direct and
every DPU path are not registered.  GpuSort, numeric aggregation and
partitionwise GpuPreAgg remain disabled.  GPU-Direct and SELECT-INTO-Direct
cannot be enabled.

The implementation assumes the standard planner (`optimizer=off`).  ORCA
does not consume the standard planner hook and therefore cannot produce a
PG-Strom plan.

Cloudberry stores global table statistics in `RelOptInfo`, but requires Path
rows and running cost per QE.  `gpu_scan.c` divides rows, pages, and running
work by `planner_segment_count(baserel->cdbpolicy)`, while leaving startup cost
per QE.  It also initializes locus, memory/hazard/rescan/same-slice fields and
synchronizes the effective parallel worker count with the locus.

The current source also has an experimental, Cloudberry-only mixed qualifier
path.  `pg_strom.cloudberry_enable_host_quals` is off by default.  When enabled,
a scan with at least one GPU-executable qualifier may evaluate remaining
host-only qualifiers in each QE using `ExecQual()` after GPU filtering.  A
pure host-only query still retains the native scan path.  This source change
has completed real multi-Segment GPU acceptance for plans, CPU/GPU signatures,
query cancellation, SIGHUP, and SIGKILL/crash recovery; see
`CLOUDBERRY_GPUSCAN_HOST_QUALS_MILESTONE.md`.

The experimental GpuPreAgg path is also default-off.  When explicitly enabled,
each QE fuses a device-only GpuScan with local partial aggregation.  M5a keeps
GROUP BY results local when the keys provably cover the input distribution key,
and executes one CPU final aggregate per QE without a pre-final Gather Motion.
Other GROUP BY shapes and global aggregates send partial rows through a real
Cloudberry Motion and use one CPU final aggregate to merge groups across
Segments.  Its first whitelist is count/sum/min/max on
integer and floating-point inputs; mixed quals, numeric, aggregate FILTER,
DISTINCT aggregates, partitionwise aggregation and GPU-Sort retain native
plans.  Source and acceptance assets are complete.  Real dual-Primary GPU
M1/M2/M3 acceptance and the post-failure full regression completed on
2026-08-10; see `CLOUDBERRY_GPUPREAGG_MVP_DESIGN.md`.

The M4a planner now estimates global groups once and derives expected local
groups per QE from the input locus.  Local groups drive partial-row/DMA cost
and a shared planner/executor final-buffer sizing formula; the resulting
per-QE GPU memory estimate is carried in `Path.memory`, oversized buffers fall
back before path creation, and `EXPLAIN` reports estimated versus actual
final-buffer use.  Cloudberry's native Motion and CPU aggregate paths continue
to own their respective costs.  These estimates are structural safeguards,
not benchmark-calibrated performance claims, especially while all demo
postmasters share one GPU.

M4a completed real GPU acceptance on 2026-08-13 using one coordinator and two
Primaries sharing one GPU.  Six positive query shapes each matched their CPU
baseline for three executions, all positive plans exposed the expected
Gather-only placement and sizing information, and the established unsupported
shapes retained native plans.  This validates the structural model on the
single-host topology; cardinality/cost calibration, high-cardinality pressure,
multi-host execution, concurrency isolation, and performance claims remain
outside M4a.

The shared-GPU P0 implements host-wide GPU allocation admission for the actual
single-host topology.  Independent coordinator/Segment GPU Services share
a per-UID/per-GPU-UUID budget ledger; memory-pool segments, direct query
buffers, and GpuPreAgg expansion peaks reserve before CUDA allocation and
release on all normal cleanup paths.  Extension 6.3 exposes dynamic accounting,
live Service count, per-Service/theoretical host quotas, explicit safety margin,
overcommit state, and last/max admission requests in
`pgstrom.gpu_service_status`.

Real single-host shared-GPU acceptance completed on 2026-08-13.  A 24-client
GpuPreAgg run produced successful CPU-matching queries plus explicit
pre-allocation budget rejections without a real CUDA OOM; three query-cancel
cycles and three GPU-Service SIGKILL/recovery cycles passed, stale owner
reclamation advanced from zero to three, and reservations returned to the
512MiB idle pool baseline.  The post-failure M1--M4a matrix then passed in
full.  This establishes allocation isolation for the tested single-host
topology, not multi-host coordination, resource-group fairness, or a
performance claim; see `CLOUDBERRY_SHARED_GPU_BUDGET_DESIGN.md`.

The 6.3 acceptance matrix also covers GpuScan+GpuScan,
GpuScan+GpuPreAgg, and a superuser-only post-reservation allocation-failure
injection.  Real GPU acceptance completed on 2026-08-13: both concurrency
pairs matched CPU and drained resources, the then-current planner-derived 1GiB GpuPreAgg
request was visible in admission status, and the injected failure produced no
leak or partial result before a successful recovery query.  Together with the
earlier multi-GpuPreAgg, cancel and SIGKILL runs, the expanded P0a/P0b/P0c
checklist is fully accepted for the tested single-host topology.

M4b now replaces the fixed 1GiB grouped final-buffer floor with a 16MiB
minimum, 2MiB alignment, and geometric expansion.  `EXPLAIN ANALYZE` reports
group and byte estimate/actual ratios, while `GpuPreAgg Cost` separates GPU
setup, host-device DMA, partial aggregation, QE-to-QD Motion, and CPU final
aggregation without duplicating native Motion/Agg costing.  The new normal-
planner acceptance runner leaves multiphase aggregation, scan choice, and all
GPU/CPU/Motion cost parameters unforced.  Source, static, normal-planner, and
real-GPU M4b acceptance completed on 2026-08-13.  Low-cardinality buffers were
16MiB, high-cardinality group estimation was within 1.02x, detail-to-partial
Motion rows fell from 2,000,000 to 2,000, all 24 concurrent clients succeeded,
and the combined concurrency/failure rollback matrix drained cleanly.  See
`CLOUDBERRY_GPUPREAGG_M4B_DESIGN.md`.

M5a implements the colocated GROUP BY local-final path.  The planner preserves
a projected Hashed locus only when the full distribution key survives the
partial target, skips the SingleQE Motion in that case, and retains
Gather-final for every unproven shape.  Source, static, normal-planner and real
GPU acceptance completed on 2026-08-13 in the single-host 1 QD + 2 Primary
shared-GPU topology.  Colocated plans placed one CPU local final directly above
GpuPreAgg on each QE, non-colocated plans retained Gather-final, both result
digests matched CPU, and the full concurrency/cancel/failure regression drained
to its idle resource baseline.  See `CLOUDBERRY_GPUPREAGG_M5A_DESIGN.md`.

M5b adds CPU-final HAVING support for grouping keys and the existing
count/sum/min/max integer/float aggregate whitelist.  HAVING aggregate
expressions are rewritten to consume GPU partial states and are evaluated only
by the CPU final Agg, after a colocated local final or a non-colocated/global
Gather-final.  NULL and UNKNOWN therefore retain native PostgreSQL semantics;
FILTER, DISTINCT, numeric and unreplaceable HAVING aggregates safely retain
native plans.  Source, static and real-GPU acceptance completed on 2026-08-14
in the single-host 1 QD + 2 Primary shared-GPU topology.  Colocated,
grouping-key, non-colocated, NULL/UNKNOWN and empty-input CPU/GPU results
matched; unsupported FILTER, DISTINCT and numeric HAVING aggregates retained
native plans.  See `CLOUDBERRY_GPUPREAGG_HAVING_DESIGN.md`.

## Development topology constraint

The available development and acceptance environment is one host with multiple
Segment postmasters sharing one physical GPU.  It cannot deploy Segments on
different hosts with an independent GPU per host.  Work in this tree may claim
single-host plan correctness, result correctness, resource isolation,
concurrency and recovery evidence.  It must not claim multi-host or multi-GPU
scaling, cross-host load balancing, or independent-GPU performance.  Near-term
features are prioritized only when their correctness and resource behavior can
be closed in this topology; multi-host GPU coordination and performance-only
GpuHashJoin scaling are outside the current validation plan.

`src/backend/cdb/cdbplan.c` recursively mutates `CustomScan.custom_plans`,
`custom_exprs`, and `custom_scan_tlist` during QD-to-QE plan rewriting.
`custom_private` remains opaque extension data.

## Requirements and demo

The GPU host must be Linux x86_64 with a compute capability 7.5 or newer GPU
and CUDA Toolkit 12.2 update 1 or newer.  PG-Strom must be present in
`shared_preload_libraries` on the coordinator and all primary/mirror segment
instances.  See `cloudberry/demo/README.md` for the experimental multi-segment
technical demo.  It requires at least two up preferred primaries, dynamically
checks the Motion segment count, and validates uniform, skewed, and tiny heap
tables.  A single-host run remains serial because its services share one GPU.

The current source-only environment can run:

```sh
gpcontrib/pg_strom/cloudberry/test_static_mvp.sh
make -C src/backend/cdb cdbplan.o
```

The host sources are compile-checked against Cloudberry 16.9 server headers.
The service-observability and mixed-qualifier changes have also completed a
fresh build and acceptance run on the GPU host.  A real build still requires
CUDA headers, `nvcc`, and the CUDA driver library; temporary declarations are
only suitable for source-level host compilation.

## Service observability and recovery development

The Cloudberry extension version is 6.1.  It exposes the postmaster-local GPU
Service state through `pgstrom.gpu_service_status_local()` on the coordinator,
`pgstrom.gpu_service_status_segments()` on all Primaries, and the combined
`pgstrom.gpu_service_status` view.  The rows include service PID/generation,
readiness, configured/actual workers, clients and command counters, fatbin
name, and the host/device storage configuration signature.

`cloudberry/demo/run_query_cancel.sh` automates cancellation and command-drain
checks.  `run_failure_recovery.sh` supports the established SIGHUP model and an
explicitly double-opted-in SIGKILL model.  Query cancel, SIGHUP, and
SIGKILL/crash recovery have completed real multi-Segment GPU acceptance; see
`CLOUDBERRY_GPUSCAN_OBSERVABILITY_RECOVERY_MILESTONE.md` and
`CLOUDBERRY_GPUSCAN_HOST_QUALS_MILESTONE.md`.
