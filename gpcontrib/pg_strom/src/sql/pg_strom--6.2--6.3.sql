--
-- Static host-budget diagnostics and acceptance fault injection
--
DROP VIEW pgstrom.gpu_service_status;
DROP FUNCTION pgstrom.gpu_service_status_segments();
DROP FUNCTION pgstrom.gpu_service_status_local();

CREATE FUNCTION pgstrom.gpu_service_status_local()
RETURNS TABLE
(
  content_id int, postmaster_pid int, service_pid int,
  service_generation bigint, ready boolean, gpu_id int, device_name text,
  configured_workers int, actual_workers int, active_clients int,
  queued_commands bigint, active_commands bigint, submitted_commands bigint,
  completed_commands bigint, failed_commands bigint, cancelled_commands bigint,
  shared_budget_bytes bigint, shared_reserved_bytes bigint,
  local_reserved_bytes bigint, budget_admissions bigint,
  budget_rejections bigint, budget_waits bigint, stale_reclaims bigint,
  device_total_bytes bigint, host_service_count int,
  service_budget_bytes bigint, host_configured_budget_sum bigint,
  safety_margin_bytes bigint, host_safe_capacity_bytes bigint,
  budget_overcommitted boolean, last_request_bytes bigint,
  max_request_bytes bigint, fatbin_name text, device_config text
)
AS 'MODULE_PATHNAME', 'pgstrom_gpu_service_status'
LANGUAGE C VOLATILE EXECUTE ON COORDINATOR;

CREATE FUNCTION pgstrom.gpu_service_status_segments()
RETURNS TABLE
(
  content_id int, postmaster_pid int, service_pid int,
  service_generation bigint, ready boolean, gpu_id int, device_name text,
  configured_workers int, actual_workers int, active_clients int,
  queued_commands bigint, active_commands bigint, submitted_commands bigint,
  completed_commands bigint, failed_commands bigint, cancelled_commands bigint,
  shared_budget_bytes bigint, shared_reserved_bytes bigint,
  local_reserved_bytes bigint, budget_admissions bigint,
  budget_rejections bigint, budget_waits bigint, stale_reclaims bigint,
  device_total_bytes bigint, host_service_count int,
  service_budget_bytes bigint, host_configured_budget_sum bigint,
  safety_margin_bytes bigint, host_safe_capacity_bytes bigint,
  budget_overcommitted boolean, last_request_bytes bigint,
  max_request_bytes bigint, fatbin_name text, device_config text
)
AS 'MODULE_PATHNAME', 'pgstrom_gpu_service_status'
LANGUAGE C VOLATILE EXECUTE ON ALL SEGMENTS;

CREATE VIEW pgstrom.gpu_service_status AS
SELECT * FROM pgstrom.gpu_service_status_local()
UNION ALL
SELECT * FROM pgstrom.gpu_service_status_segments();

CREATE FUNCTION pgstrom.shared_gpu_budget_inject_oom_segments(gpu_id int, count int)
RETURNS SETOF integer
AS 'MODULE_PATHNAME', 'pgstrom_shared_gpu_budget_inject_oom'
LANGUAGE C VOLATILE STRICT EXECUTE ON ALL SEGMENTS;

REVOKE ALL ON FUNCTION pgstrom.shared_gpu_budget_inject_oom_segments(int, int)
FROM PUBLIC;
