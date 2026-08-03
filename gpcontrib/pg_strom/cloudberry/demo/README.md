# Multi-segment GPU demo

Use one coordinator and at least two up preferred primary segments.  The
initial technical demo may run every instance on one host and share one NVIDIA
GPU, but it must run serially.  Copy the settings in `postgresql.conf.mvp` to
the coordinator, every primary, and every mirror, install PG-Strom using the
Cloudberry `pg_config`, and restart the cluster.  Do not use `LOAD 'pg_strom'`:
the module requires `shared_preload_libraries`.

Confirm CUDA 12.2 update 1 or newer, compute capability 7.5 or newer, and a
GPU Service startup message in both coordinator and segment logs.  Then run:

```sh
source /path/to/cloudberry/greenplum_path.sh
createdb pgstrom_mvp
PGDATABASE=pgstrom_mvp ./gpcontrib/pg_strom/cloudberry/demo/run_demo.sh
```

The runner discovers the number of up preferred primaries from
`gp_segment_configuration` and refuses a single-primary or degraded topology.
It requires `Custom Scan (GpuScan)` below a Motion for that segment count and
compares CPU/GPU signatures for three distributed heap shapes:

- a uniformly distributed two-million-row table;
- a skewed table whose rows all reside on one primary;
- a tiny table whose rows all reside on one primary.

The latter two make the remaining QEs execute empty local scans.  They also
cover NULL projection and negative integer/numeric values.  The runner retains
the LIMIT, prepared parameter, repeated execution, and lateral rescan checks,
then verifies that `optimizer=on`, AO, AOCO, partitioned tables, and a
host-only regular-expression filter do not produce GpuScan.

Each CPU signature is compared with three GPU executions by default.  Override
the positive iteration count when a longer smoke run is useful:

```sh
PGSTROM_MVP_REPEAT=10 PGDATABASE=pgstrom_mvp \
  ./gpcontrib/pg_strom/cloudberry/demo/run_demo.sh
```

The tiny-table GpuScan is forced with `enable_seqscan=off` to test distributed
execution, not to make a performance claim.  Inspect the verbose plans and the
reported per-segment row distribution when diagnosing a failure.

Cancellation and service-failure checks are deliberately manual because the
service PID and cluster manager are installation-specific:

1. Run the filtered aggregate from one `psql`, cancel it with `pg_cancel_backend`
   from another, and confirm the client receives query cancellation.
2. Stop only the primary segment's PG-Strom GPU Service and run a query whose
   earlier plan showed GpuScan.  It must report a clear GPU/service error and
   cancel the whole query; it must not silently return CPU results.
3. Restart that instance and run `SELECT 1` and the CPU/GPU signature again to
   confirm the cluster remains usable.

Do not run concurrent acceptance traffic while QD and QEs share one GPU.  The
configured pool limit applies independently to each GPU Service; it is not
resource isolation between processes.  A coordinator, three primaries, and
three mirrors can start seven independent services even though mirrors do not
normally execute the query.  The sample uses the minimum accepted 20% hard
limit and a 256MB allocation segment; idle services do not reserve 20% eagerly.
