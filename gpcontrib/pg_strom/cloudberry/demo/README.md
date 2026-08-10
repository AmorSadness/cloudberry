# Multi-segment GPU demo

Use one coordinator and at least two up preferred primary segments.  The
initial technical demo may run every instance on one host and share one NVIDIA
GPU, but it must run serially.  Do not use `LOAD 'pg_strom'`: the module
requires `shared_preload_libraries`.

## End-to-end build and validation

The following procedure builds the current checkout, creates an isolated
mirrorless cluster with one QD and two preferred primaries, and runs the GPU
acceptance test.  Run it as a non-root Cloudberry development user.  The host
must have the Cloudberry build dependencies, passwordless SSH to its own
hostname, free demo ports, CUDA Toolkit 12.2 update 1 or newer, and a GPU with
compute capability 7.5 or newer.

Choose an installation directory and a new empty demo directory outside the
source tree:

```sh
export CB_SRC=/path/to/cloudberry
export CB_INSTALL=/path/to/cloudberry-install
export CB_DEMO_ROOT=/path/to/cloudberry-pgstrom-demo
export CB_BUILD_JOBS="$(nproc)"

cd "$CB_SRC"
git rev-parse HEAD
git status --short
nvidia-smi
nvcc --version
ssh "$(hostname)" true
```

Configure Cloudberry explicitly with its 32KB heap and WAL block sizes.  The
remaining feature switches match the configuration used for this MVP; add
site-specific include/library paths when dependencies are installed outside
the system search path.

```sh
cd "$CB_SRC"

./configure \
  --prefix="$CB_INSTALL" \
  --enable-orca \
  --with-blocksize=32 \
  --with-wal-blocksize=32 \
  --with-ssl=openssl \
  --with-libxml \
  --with-lz4 \
  --with-zstd \
  --with-python \
  --with-pythonsrc-ext \
  --with-perl

make -j"$CB_BUILD_JOBS"
make -C contrib -j"$CB_BUILD_JOBS"
make install
make -C contrib install

source "$CB_INSTALL/cloudberry-env.sh"
postgres --version
pg_config --configure
```

Build PG-Strom only after installing Cloudberry, and always select the new
installation's `pg_config`.  Do not assume that it is located at a particular
`$CB_INSTALL/bin` path; resolve it from the environment installed by
Cloudberry and verify its bindir first.  Cleaning prevents generated device
headers from a different server build from being reused.

```sh
source "$CB_INSTALL/cloudberry-env.sh"
export PG_CONFIG="$(command -v pg_config)"
test -x "$PG_CONFIG"
"$PG_CONFIG" --bindir

make -C "$CB_SRC/gpcontrib/pg_strom/src" \
  PG_CONFIG="$PG_CONFIG" \
  PGSTROM_WITH_ARROW=0 \
  clean

make -C "$CB_SRC/gpcontrib/pg_strom/src" \
  PG_CONFIG="$PG_CONFIG" \
  PGSTROM_WITH_ARROW=0 \
  -j"$CB_BUILD_JOBS"

make -C "$CB_SRC/gpcontrib/pg_strom/src" \
  PG_CONFIG="$PG_CONFIG" \
  PGSTROM_WITH_ARROW=0 \
  install

test -f "$(pg_config --pkglibdir)/pg_strom.so"
test -f "$(pg_config --sharedir)/extension/pg_strom.control"
grep PGSTROM_DEVICE_BLCKSZ \
  "$CB_SRC/gpcontrib/pg_strom/src/pgstrom_device_config.h"
```

The generated header must report `PGSTROM_DEVICE_BLCKSZ 32768`.

Create a fresh mirrorless demo cluster.  `gpdemo` initializes and starts one
QD plus two primary segments.  Passing the PG-Strom settings during cluster
initialization ensures that every instance starts with the same preload and
memory-pool configuration.  The chosen demo directory must not contain an
existing cluster because `gpdemo` owns and may replace its generated files.

```sh
mkdir -p "$CB_DEMO_ROOT"
cd "$CB_DEMO_ROOT"

export PORT_BASE=7000
export NUM_PRIMARY_MIRROR_PAIRS=2
export WITH_MIRRORS=false
export WITH_STANDBY=false
export DATADIRS="$CB_DEMO_ROOT/datadirs"
export BLDWRAP_POSTGRES_CONF_ADDONS='fsync=on|shared_preload_libraries=pg_strom|max_worker_processes=16|pg_strom.gpu_mempool_segment_sz=256MB|pg_strom.gpu_mempool_max_ratio=0.20|pg_strom.cpu_fallback=off|pg_strom.enabled=on|pg_strom.enable_gpuscan=on'

gpdemo -c
gpdemo
source "$CB_DEMO_ROOT/gpdemo-env.sh"
gpstate -s
```

For a previously initialized cluster, source both environment files before
starting it:

```sh
source "$CB_INSTALL/cloudberry-env.sh"
source "$CB_DEMO_ROOT/gpdemo-env.sh"
gpstart -a
```

Verify that both preferred primaries are up and no mirror is acting as a
primary:

```sh
psql -X -d postgres -c "
  SELECT content, hostname, port, role, preferred_role, status
  FROM gp_segment_configuration
  WHERE content >= 0
  ORDER BY content, preferred_role;"

psql -X -At -d postgres -c "
  SELECT count(DISTINCT content) FILTER (
           WHERE preferred_role='p' AND content >= 0) AS configured,
         count(DISTINCT content) FILTER (
           WHERE role='p' AND preferred_role='p'
             AND status='u' AND content >= 0) AS up_preferred
  FROM gp_segment_configuration;"
```

The second query must return `2|2`.  Confirm that PG-Strom is preloaded on the
QD and both QEs:

```sh
psql -X -d postgres -c "
  SHOW shared_preload_libraries;
  SHOW pg_strom.gpu_mempool_segment_sz;
  SHOW pg_strom.gpu_mempool_max_ratio;
  SHOW pg_strom.cpu_fallback;"

psql -X -d postgres -c "
  SELECT gp_segment_id,
         current_setting('shared_preload_libraries') AS preload,
         current_setting('pg_strom.gpu_mempool_max_ratio') AS pool_ratio,
         current_setting('pg_strom.cpu_fallback') AS cpu_fallback
  FROM gp_dist_random('gp_id')
  ORDER BY gp_segment_id;"
```

PG-Strom 6.1 adds the Cloudberry-local GPU Service status functions.  After
installing the new library and SQL files, restart every QD/QE postmaster so it
allocates the enlarged shared-state structure.  Then upgrade an existing
acceptance database; a new `CREATE EXTENSION` installs 6.1 directly:

```sh
psql -X -d pgstrom_mvp -c "ALTER EXTENSION pg_strom UPDATE TO '6.1';"
psql -X -d pgstrom_mvp -c "SELECT * FROM pgstrom.gpu_service_status ORDER BY content_id, gpu_id;"
```

The combined view contains the coordinator (`content_id=-1`) and every
Primary.  `gpu_service_status_local()` and `gpu_service_status_segments()`
are also available when a caller needs only one placement.  Every ready row
must show `actual_workers=configured_workers`.  Counters and generation are
postmaster-shared and survive a controlled GPU Service background-worker
restart within one shared-memory epoch.  Segment crash recovery recreates
shared memory, so these cumulative fields can reset.  Queued, active, client,
PID and readiness fields describe the current generation.

Run the source-only checks, create the acceptance database, and execute the
multi-segment runner:

```sh
cd "$CB_SRC"
bash -n gpcontrib/pg_strom/cloudberry/demo/run_demo.sh
gpcontrib/pg_strom/cloudberry/test_static_mvp.sh
make -C src/backend/cdb cdbplan.o

createdb pgstrom_mvp
PGDATABASE=pgstrom_mvp \
PGSTROM_MVP_REPEAT=3 \
PGSTROM_MVP_READY_TIMEOUT=60 \
./gpcontrib/pg_strom/cloudberry/demo/run_demo.sh
```

If `pgstrom_mvp` already exists, skip `createdb`.  A successful run exits with
status zero and ends with `Multi-segment GpuScan plans and CPU/GPU signatures
passed on 2 primaries.`  Check the QD and QE logs for the fatbin and worker
startup messages:

```sh
grep -R -E 'PG-Strom fatbin image is ready|GPU[0-9]+ workers' \
  "$CB_DEMO_ROOT/datadirs"/*/*/log \
  "$CB_DEMO_ROOT/datadirs"/qddir/*/log
```

Stop the validation cluster without deleting its data using:

```sh
source "$CB_INSTALL/cloudberry-env.sh"
source "$CB_DEMO_ROOT/gpdemo-env.sh"
gpstop -a
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
the positive iteration count when a longer smoke run is useful.  On cold
start, the runner waits up to `PGSTROM_MVP_READY_TIMEOUT` seconds for the QD
and every Primary GPU Service to report a complete worker pool.  A timeout
prints one diagnostic row per expected content, including missing services,
PID, generation, worker counts, clients, and queued/active commands:

```sh
PGSTROM_MVP_REPEAT=10 PGDATABASE=pgstrom_mvp \
  ./gpcontrib/pg_strom/cloudberry/demo/run_demo.sh
```

The tiny-table GpuScan is forced with `enable_seqscan=off` to test distributed
execution, not to make a performance claim.  Inspect the verbose plans and the
reported per-segment row distribution when diagnosing a failure.

## Experimental mixed host/device qualifiers

Cloudberry builds expose `pg_strom.cloudberry_enable_host_quals`, a USERSET
experimental GUC that is off by default.  Enabling it allows GpuScan only when
the query has at least one GPU-executable condition; remaining host-only
conditions are evaluated by `ExecQual` in each QE after GPU filtering:

```sql
SET optimizer=off;
SET pg_strom.enabled=on;
SET pg_strom.enable_gpuscan=on;
SET pg_strom.cloudberry_enable_host_quals=on;

EXPLAIN (ANALYZE, VERBOSE, COSTS OFF)
SELECT id, amount, payload
FROM pgstrom_mvp_heap
WHERE grp BETWEEN 101 AND 207
  AND amount >= 500.00
  AND payload ~ '^[0-7]';
```

The plan must show both `GPU Scan Quals` and a standard `Filter`.  A query with
only the regular expression still uses a native scan even when the GUC is on.
`run_demo.sh` compares CPU/GPU signatures for mixed qualifiers on the uniform,
skewed, and tiny tables, including NULL, prepared parameters, LIMIT, and a
lateral/rescan shape.  This capability remains default-off and experimental,
but its design exit matrix has passed on a real 1 QD + 2 Primary GPU host,
including query cancel, SIGHUP, and SIGKILL/crash recovery.  See
`CLOUDBERRY_GPUSCAN_HOST_QUALS_MILESTONE.md` for the recorded evidence.

## GPU Service failure and recovery

After `run_demo.sh` succeeds, the single-host failure runner can exercise one
QE's service restart path.  It reads the target segment's postmaster PID file,
verifies the process parent/arguments, and identifies exactly one direct child
named `PG-Strom GPU Service`.  It never signals the postmaster or QE backend.

The action requires an explicit opt-in because it sends `SIGHUP` directly to
the selected service.  PG-Strom defines this signal as a controlled exit with
status 1; the postmaster restarts the background worker after its configured
five-second delay.

```sh
cd "$CB_SRC"

PGDATABASE=pgstrom_mvp \
PGSTROM_MVP_ALLOW_SERVICE_RESTART=1 \
PGSTROM_MVP_TARGET_CONTENT=0 \
PGSTROM_MVP_RECOVERY_CYCLES=3 \
./gpcontrib/pg_strom/cloudberry/demo/run_failure_recovery.sh
```

For every cycle the runner verifies all of the following:

- the old GPU Service PID exits while its segment postmaster stays up;
- a distributed GpuScan fails with a GPU/service error and emits no partial
  result row while the target service is unavailable;
- the postmaster creates a new service PID;
- the SQL-visible service generation increases and reports a ready, fully
  populated worker pool;
- a new `GPU0 workers - N startup` log entry appears;
- the recovered GPU signature again equals the CPU signature.

`PGSTROM_MVP_RECOVERY_TIMEOUT` controls each wait and defaults to 30 seconds.
The runner intentionally refuses a remote target host; multi-host process
coordination is outside this milestone.  A successful run ends with `GPU
Service failure propagation and recovery passed`.

`SIGKILL` is a separate, stronger fault model.  It requires a second explicit
authorization and may cause the Segment postmaster to enter crash recovery,
depending on background-worker and platform behavior:

```sh
PGDATABASE=pgstrom_mvp \
PGSTROM_MVP_ALLOW_SERVICE_RESTART=1 \
PGSTROM_MVP_ALLOW_HARD_FAILURE=1 \
PGSTROM_MVP_SERVICE_SIGNAL=KILL \
PGSTROM_MVP_TARGET_CONTENT=0 \
PGSTROM_MVP_RECOVERY_CYCLES=3 \
./gpcontrib/pg_strom/cloudberry/demo/run_failure_recovery.sh
```

Run this only on a disposable acceptance cluster.  The runner still signals
only the uniquely identified GPU Service child; it checks that the Segment
postmaster remains available, the distributed query does not emit a partial
row, a ready replacement PID and worker pool appear, queues recover, and the
result signature is restored.  If SIGKILL triggers Segment crash recovery,
the postmaster recreates shared memory and the generation can restart from a
lower value; the runner reports this epoch reset instead of requiring an
increase across incomparable shared-memory lifetimes.  CUDA-fatal recovery is
not claimed by this runner.

## Query cancellation

The cancellation runner first verifies that its per-iteration statement uses
GpuScan.  It then executes that statement repeatedly from a server-side
PL/pgSQL loop in one identifiable coordinator backend.  Separate statement
executions are intentional: Cloudberry may place a required `Materialize`
below Motion for a correlated lateral query, causing GpuScan to run only once
while the remaining work filters cached rows on the CPU.  The runner waits for
the monotonic `submitted_commands` counter to increase, calls
`pg_cancel_backend` on the still-active loop backend, then verifies that
commands drain and a fresh CPU/GPU signature still agrees:

```sh
PGDATABASE=pgstrom_mvp \
PGSTROM_MVP_CANCEL_CYCLES=3 \
PGSTROM_MVP_CANCEL_TIMEOUT=30 \
./gpcontrib/pg_strom/cloudberry/demo/run_query_cancel.sh
```

The acceptance cluster must otherwise be idle; the runner checks this before
each cycle and requires `active_clients`, `queued_commands`, and
`active_commands` to return to zero afterwards.  These three fields are
instantaneous gauges, so a fast GPU command may pass through them between two
distributed status samples.  They are recorded for diagnostics but are not a
precondition for issuing cancel; an increase of the cumulative
`submitted_commands` counter is the stable synchronization point.
`cancelled_commands` counts commands skipped or unable to return a response
after the backend closes its Service socket; it does not count SQL statements
and need not increase for every `pg_cancel_backend()` call.  A cancellation can
arrive just after the current GPU command has returned successfully.  The
runner therefore requires every newly submitted command to reach one of the
completed, failed, or cancelled terminal counters and requires all queues to
drain.  If the runner exits on an error while its target remains alive, the
exit trap first cancels the exact PID/application-name pair.  It waits briefly
and terminates only that same backend if cancellation did not make it exit,
then cleans up the local `psql` process.

Do not run concurrent acceptance traffic while QD and QEs share one GPU.  The
configured pool limit applies independently to each GPU Service; it is not
resource isolation between processes.  The mirrorless sample starts three
independent services: one for the QD and one for each of its two primaries.
Enabling mirrors starts additional services even though mirrors do not normally
execute the query.  The sample uses the minimum accepted 20% hard limit and a
256MB allocation segment; idle services do not reserve 20% eagerly.

## Gather-only GpuPreAgg MVP

GpuPreAgg is registered as a default-off experimental path.  First run the
regular demo so that its uniform, skewed, small, AO/AOCO, and partitioned test
relations exist.  Then run the dedicated acceptance runner:

```sh
PGDATABASE=pgstrom_mvp \
PGSTROM_GPUPREAGG_REPEAT=3 \
./gpcontrib/pg_strom/cloudberry/demo/run_gpupreagg_mvp.sh
```

The runner requires at least two up preferred Primaries and verifies that
`pg_strom.enable_gpupreagg`, numeric aggregation, partitionwise GpuPreAgg, and
GpuSort are all off by default.  For supported queries it enables only the
Gather-only MVP and requires the following logical placement:

```text
CPU Final Aggregate
  -> Motion from every Primary
       -> Custom Scan (GpuPreAgg)
```

It compares CPU and GPU results for groups spanning Segments, a global
aggregate, single-Segment skew, one nonempty QE, and an entirely empty input.
It also verifies safe fallback for no device qual, mixed host/device quals,
numeric aggregation, aggregate `FILTER`, `HAVING`, AO/AOCO, partitioned tables,
and ORCA.  Passing this runner proves the M1/M2 result and placement matrix; it
does not by itself complete query-cancel or GPU Service failure recovery
acceptance for GpuPreAgg.

### GpuPreAgg cancellation and failure recovery

The M3 runners reuse the established GpuScan cancellation and recovery
framework but select a strict GpuPreAgg mode.  They first require a real
`Custom Scan (GpuPreAgg)` below a multi-Primary Motion, use only the MVP
`count`/`sum(int8)`/`min`/`max` aggregate whitelist, and apply the same
correctness-only planner costs as the M1/M2 runner.

Run three cancellation cycles on an otherwise idle acceptance cluster:

```sh
PGDATABASE=pgstrom_mvp \
PGSTROM_GPUPREAGG_CANCEL_CYCLES=3 \
PGSTROM_GPUPREAGG_CANCEL_TIMEOUT=30 \
./gpcontrib/pg_strom/cloudberry/demo/run_gpupreagg_cancel.sh
```

The runner waits for a GPU Service submission before cancelling the exact QD
backend.  It requires the client to report cancellation, every submitted
command to reach a terminal counter, all client/queue/active gauges to drain,
and a fresh GpuPreAgg result to match its CPU baseline.

The controlled SIGHUP test needs explicit authorization and signals only the
uniquely identified GPU Service child of the selected Segment postmaster:

```sh
PGDATABASE=pgstrom_mvp \
PGSTROM_GPUPREAGG_ALLOW_SERVICE_RESTART=1 \
PGSTROM_GPUPREAGG_SERVICE_SIGNAL=HUP \
PGSTROM_GPUPREAGG_TARGET_CONTENT=0 \
PGSTROM_GPUPREAGG_RECOVERY_CYCLES=3 \
PGSTROM_GPUPREAGG_RECOVERY_TIMEOUT=30 \
./gpcontrib/pg_strom/cloudberry/demo/run_gpupreagg_failure_recovery.sh
```

Run SIGKILL only on a disposable acceptance cluster.  It requires a second
explicit authorization because it can trigger Segment crash recovery:

```sh
PGDATABASE=pgstrom_mvp \
PGSTROM_GPUPREAGG_ALLOW_SERVICE_RESTART=1 \
PGSTROM_GPUPREAGG_ALLOW_HARD_FAILURE=1 \
PGSTROM_GPUPREAGG_SERVICE_SIGNAL=KILL \
PGSTROM_GPUPREAGG_TARGET_CONTENT=0 \
PGSTROM_GPUPREAGG_RECOVERY_CYCLES=3 \
PGSTROM_GPUPREAGG_RECOVERY_TIMEOUT=60 \
./gpcontrib/pg_strom/cloudberry/demo/run_gpupreagg_failure_recovery.sh
```

For both signals, the distributed query must fail without emitting the
`UNEXPECTED_PARTIAL_RESULT` marker while the target service is unavailable.
The runner then requires a replacement service and worker pool, SQL-visible
readiness, a surviving Segment postmaster, and a recovered GpuPreAgg signature
equal to the CPU baseline.  A generation reset after SIGKILL is accepted only
when Segment crash recovery recreated the shared-memory epoch.
