# Cloudberry GpuScan 可观测性、取消与强故障恢复设计

> 前置基线：`CLOUDBERRY_GPUSCAN_MULTI_SEGMENT_MILESTONE.md`  
> 开发日期：2026-08-03  
> 当前状态：代码与无 GPU 静态检查阶段；真实 GPU 验收待完成

## 1. 目标

本阶段不扩大 GpuScan 的 SQL、存储或算子能力，而是让每个 QD/QE
postmaster 的 GPU Service 状态可以被 SQL 精确读取，并自动验证 query
cancel、SIGHUP 和 SIGKILL 后的分布式失败传播与恢复。

出口如下：

1. QD 和所有 Primary 都能报告 Service PID、generation、ready、worker、
   command counter、fatbin 和 device storage config；
2. query cancel 后所有 QE 的客户端、排队和活动命令归零，后续签名恢复；
3. SIGHUP 与 SIGKILL 均不返回部分结果，新 Service generation 增长；
4. 新 Service 只有在实际 worker 数达到配置值后才报告 ready；
5. 原多 Segment 正确性、负向边界和静态检查不退化。

## 2. 保持不变的能力边界

- PostgreSQL planner，`optimizer=off`；
- 普通分布式、非分区 heap 表；
- 至少一个 device qual，且不包含 host qual；
- `cpu_fallback=off` 用于故障验收；
- 不开放 ORCA、AO/AOCO、分区、GpuJoin、GpuPreAgg、GpuSort、GpuCache、
  GPU-Direct 或 DPU；
- 不修改成本模型，不形成性能结论；
- 不宣称多个 Service 之间已实现主机级 GPU 资源隔离；
- SIGKILL 不等价于 CUDA fatal，Mirror/FTS 与多主机也不在本阶段出口中。

## 3. 共享状态设计

`gpuServSharedState` 属于 postmaster shared memory，因此在 GPU Service
background worker 重启后仍存在。全局状态包括：

- 当前/最近一次 `service_pid`；
- 单调递增的 `service_generation`；
- `ready` 与 active client 数；
- fatbin 文件名；
- `pg_strom.max_async_tasks`。

每个 GPU device 独立记录：

- `actual_workers`；
- `queued_commands`、`active_commands`；
- `submitted_commands`、`completed_commands`；
- `failed_commands`、`cancelled_commands`。

generation 和累计 command counter 在 Service 重启后保留。PID、ready、
worker、queue、active 和 client 描述当前 generation；新 Service 启动时先
清零这些瞬时值，重建 worker pool，最后才设置 ready。

`cancelled_commands` 是 Service 命令计数，不是 SQL statement 计数。命令在
执行前发现 backend socket 已关闭，或执行后无法向该 socket 返回响应时，
记为 cancelled。设备/执行错误记为 failed；正常完成并成功返回记为
completed。

SIGKILL 可以在 Service 来不及分类在途命令时终止进程，因此强故障之后
`completed + failed + cancelled` 不保证等于 `submitted`；差值代表未分类的
中断命令，而不是成功结果。

## 4. SQL 接口和 MPP 放置

扩展版本由 6.0 升至 6.1，升级脚本增加：

- `pgstrom.gpu_service_status_local()`：`EXECUTE ON COORDINATOR`；
- `pgstrom.gpu_service_status_segments()`：`EXECUTE ON ALL SEGMENTS`；
- `pgstrom.gpu_service_status`：合并上述两者。

C 函数只读取执行它的 postmaster shared memory，不自行连接远端实例。
`content_id=-1` 表示 QD，非负值表示对应 Primary content。status 返回的
ready 还会检查共享 PID 是否仍存活，以降低 SIGKILL 后旧 ready 值造成的
误导。

## 5. 自动验收

### 5.1 Query cancel

`cloudberry/demo/run_query_cancel.sh`：

1. 检查目标 SQL 的计划包含 GpuScan；
2. 启动重复参数化 GpuScan；
3. 同时从 SQL status 等待 QE 出现 queued/active command；
4. 定位带唯一 `application_name` 的 QD backend 并调用
   `pg_cancel_backend()`；
5. 要求客户端返回 cancellation 错误；
6. 等待所有 QE client/queue/active 归零且 cancelled counter 增长；
7. 再次比较 CPU/GPU 签名；
8. 默认连续三轮。

该 runner 要求验收集群没有其他并发 PG-Strom 查询，否则全局 client/queue
归零条件没有确定含义。

### 5.2 SIGHUP 与 SIGKILL

`cloudberry/demo/run_failure_recovery.sh` 默认继续使用 SIGHUP。设置
`PGSTROM_MVP_SERVICE_SIGNAL=KILL` 时还必须显式设置
`PGSTROM_MVP_ALLOW_HARD_FAILURE=1`。两种模式都检查：

- 目标 PID 确实是指定 Segment postmaster 的唯一直属 GPU Service；
- Service 不可用窗口内分布式查询失败且没有部分结果标记；
- Segment postmaster 保持可用；
- 新 PID 和 SQL generation 出现；
- actual/configured worker 数一致并 ready；
- worker startup 日志增加；
- 恢复后的 GPU 签名等于 CPU 基线。

SIGKILL 可能触发 Segment postmaster crash recovery；runner 记录实际行为，
但不把该行为外推为 CUDA fatal 或 Mirror failover 语义。

## 6. GPU 环境验收顺序

1. 使用目标 Cloudberry `pg_config` 构建、安装 PG-Strom；
2. 重启无 Mirror、至少双 Primary 的隔离集群；
3. 新数据库执行 `CREATE EXTENSION pg_strom`，已有数据库执行
   `ALTER EXTENSION pg_strom UPDATE TO '6.1'`；
4. 查询 `pgstrom.gpu_service_status`，确认 QD/QE 全部 ready 且 worker 数一致；
5. 运行 `run_demo.sh`；
6. 运行 `run_query_cancel.sh`；
7. 运行三轮 SIGHUP failure/recovery；
8. 仅在可丢弃集群运行三轮 SIGKILL failure/recovery；
9. 保存 verbose plan、status 快照、runner 输出和 QD/QE 日志。

上述步骤全部通过后，才能把本文“待验收”改为“已验收”。
