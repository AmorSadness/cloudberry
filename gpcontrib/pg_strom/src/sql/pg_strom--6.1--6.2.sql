--
-- Host-wide shared GPU budget observability
--
DROP VIEW pgstrom.gpu_service_status;
DROP FUNCTION pgstrom.gpu_service_status_segments();
DROP FUNCTION pgstrom.gpu_service_status_local();

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
  shared_budget_bytes    bigint,
  shared_reserved_bytes  bigint,
  local_reserved_bytes   bigint,
  budget_admissions      bigint,
  budget_rejections      bigint,
  budget_waits           bigint,
  stale_reclaims         bigint,
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
  shared_budget_bytes    bigint,
  shared_reserved_bytes  bigint,
  local_reserved_bytes   bigint,
  budget_admissions      bigint,
  budget_rejections      bigint,
  budget_waits           bigint,
  stale_reclaims         bigint,
  fatbin_name            text,
  device_config          text
)
AS 'MODULE_PATHNAME', 'pgstrom_gpu_service_status'
LANGUAGE C VOLATILE EXECUTE ON ALL SEGMENTS;

CREATE VIEW pgstrom.gpu_service_status AS
SELECT * FROM pgstrom.gpu_service_status_local()
UNION ALL
SELECT * FROM pgstrom.gpu_service_status_segments();
