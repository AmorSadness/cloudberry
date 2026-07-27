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

The Cloudberry build registers only GpuScan (plus its GPU Service), and only
offers it for a non-partitioned, ordinarily distributed heap table.  AO,
AOCO, partitioned tables, foreign/Arrow tables and coordinator-local or
replicated tables retain native scan paths.  GpuJoin, GpuPreAgg, GpuSort,
GpuCache, BRIN acceleration, SELECT-INTO-Direct and every DPU path are not
registered.  GPU-Direct and SELECT-INTO-Direct cannot be enabled.

The implementation assumes the standard planner (`optimizer=off`).  ORCA
does not consume the standard planner hook and therefore cannot produce a
PG-Strom plan.

Cloudberry stores global table statistics in `RelOptInfo`, but requires Path
rows and running cost per QE.  `gpu_scan.c` divides rows, pages, and running
work by `planner_segment_count(baserel->cdbpolicy)`, while leaving startup cost
per QE.  It also initializes locus, memory/hazard/rescan/same-slice fields and
synchronizes the effective parallel worker count with the locus.

`src/backend/cdb/cdbplan.c` recursively mutates `CustomScan.custom_plans`,
`custom_exprs`, and `custom_scan_tlist` during QD-to-QE plan rewriting.
`custom_private` remains opaque extension data.

## Requirements and demo

The GPU host must be Linux x86_64 with a compute capability 7.5 or newer GPU
and CUDA Toolkit 12.2 update 1 or newer.  PG-Strom must be present in
`shared_preload_libraries` on both coordinator and segment instances.  See
`cloudberry/demo/README.md` for the single-primary setup and acceptance steps.

The current source-only environment can run:

```sh
gpcontrib/pg_strom/cloudberry/test_static_mvp.sh
make -C src/backend/cdb cdbplan.o
```

The PG-Strom host sources have also been compile-checked against Cloudberry
16.9 server headers with temporary CUDA API declarations.  A real build still
requires CUDA headers, `nvcc`, and the CUDA driver library; declarations alone
are not a substitute for the GPU-host acceptance run.
