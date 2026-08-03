--
-- Cloudberry GpuScan service observability
--
-- The C entry point only reads the postmaster-local shared state.  Function
-- placement is expressed here so the combined view returns the coordinator
-- and every primary without opening database connections inside PG-Strom.
--

CREATE FUNCTION pgstrom.gpu_service_status_local()
RETURNS TABLE
(
  content_id             int,
  postmaster_pid         int,
  service_pid            int,
  service_generation     bigint,
  ready                  boolean,
  gpu_id                 int,
  device_name            text,
  configured_workers     int,
  actual_workers         int,
  active_clients         int,
  queued_commands        bigint,
  active_commands        bigint,
  submitted_commands     bigint,
  completed_commands     bigint,
  failed_commands        bigint,
  cancelled_commands     bigint,
  fatbin_name            text,
  device_config          text
)
AS 'MODULE_PATHNAME', 'pgstrom_gpu_service_status'
LANGUAGE C VOLATILE EXECUTE ON COORDINATOR;

CREATE FUNCTION pgstrom.gpu_service_status_segments()
RETURNS TABLE
(
  content_id             int,
  postmaster_pid         int,
  service_pid            int,
  service_generation     bigint,
  ready                  boolean,
  gpu_id                 int,
  device_name            text,
  configured_workers     int,
  actual_workers         int,
  active_clients         int,
  queued_commands        bigint,
  active_commands        bigint,
  submitted_commands     bigint,
  completed_commands     bigint,
  failed_commands        bigint,
  cancelled_commands     bigint,
  fatbin_name            text,
  device_config          text
)
AS 'MODULE_PATHNAME', 'pgstrom_gpu_service_status'
LANGUAGE C VOLATILE EXECUTE ON ALL SEGMENTS;

CREATE VIEW pgstrom.gpu_service_status AS
SELECT * FROM pgstrom.gpu_service_status_local()
UNION ALL
SELECT * FROM pgstrom.gpu_service_status_segments();
