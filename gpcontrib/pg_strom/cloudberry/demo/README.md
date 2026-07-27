# Single-primary GPU demo

Use one coordinator and one primary segment.  Both processes must see the
same NVIDIA GPU; run the demo serially.  Copy the settings in
`postgresql.conf.mvp` to both instance configurations, install PG-Strom using
the Cloudberry `pg_config`, and restart the cluster.  Do not use
`LOAD 'pg_strom'`: the module requires `shared_preload_libraries`.

Confirm CUDA 12.2 update 1 or newer, compute capability 7.5 or newer, and a
GPU Service startup message in both coordinator and segment logs.  Then run:

```sh
source /path/to/cloudberry/greenplum_path.sh
createdb pgstrom_mvp
PGDATABASE=pgstrom_mvp ./gpcontrib/pg_strom/cloudberry/demo/run_demo.sh
```

The runner requires `Custom Scan (GpuScan)` in `EXPLAIN ANALYZE`, compares an
aggregate signature with PG-Strom disabled and enabled, exercises prepared
parameters, repeated execution, a lateral rescan shape, and LIMIT, then checks
that `optimizer=on`, AO, AOCO, partitioned tables, and a regular-expression
filter do not produce GpuScan.  Inspect the verbose plan to confirm that the
Custom Scan executes in a QE slice.

Cancellation and service-failure checks are deliberately manual because the
service PID and cluster manager are installation-specific:

1. Run the filtered aggregate from one `psql`, cancel it with `pg_cancel_backend`
   from another, and confirm the client receives query cancellation.
2. Stop only the primary segment's PG-Strom GPU Service and run a query whose
   earlier plan showed GpuScan.  It must report a clear GPU/service error and
   cancel the whole query; it must not silently return CPU results.
3. Restart that instance and run `SELECT 1` and the CPU/GPU signature again to
   confirm the cluster remains usable.

Do not run concurrent acceptance traffic while QD and QE share one GPU.  The
40% pool limit applies independently to each GPU Service; it is not resource
isolation between processes.
