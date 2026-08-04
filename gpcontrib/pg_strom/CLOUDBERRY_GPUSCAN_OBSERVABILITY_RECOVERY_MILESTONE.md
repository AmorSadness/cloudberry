# Cloudberry GpuScan 可观测性、取消与强故障恢复里程碑总结

> 文档基线：Cloudberry `main` 分支，HEAD
> `1f1f40e24162388eea4f5617318268a33ce4699f`
> 前置基线：`CLOUDBERRY_GPUSCAN_MULTI_SEGMENT_MILESTONE.md`
> 设计基线：`CLOUDBERRY_GPUSCAN_OBSERVABILITY_RECOVERY_DESIGN.md`
> 上游基线：PG-Strom v6.1，commit
> `4d12ef415759dc48cd4c1421565e9c694b7bd3f9`
> GPU 验收日期：2026-08-04

## 1. 结论

本阶段在单机双 Primary GpuScan 技术 MVP 的基础上，完成了一个
**具备 SQL 可观测性、可重复 query cancel 验收、受控 SIGHUP 恢复以及
SIGKILL/Segment crash recovery 验收的故障处理里程碑**。

实际 GPU 环境已经证明：

- Coordinator 和两个 Primary Segment 的 GPU Service 都能通过统一 SQL
  接口报告 PID、generation、ready、worker、client、命令计数、fatbin 和
  device storage config；
- 三个 Service 均识别 Tesla T4，加载与 Cloudberry 32KB page 配置匹配的
  CUDA 12.4 fatbin，并创建 16 个 task worker；
- 多 Segment GpuScan 的均匀、倾斜和小表签名继续与 CPU 基线一致；
- query cancel 连续三轮成功，取消后所有 QE Service client、queue 和 active
  command 归零，后续 GPU 签名恢复；
- 目标 QE GPU Service 的受控 SIGHUP 连续三轮成功，每轮分布式查询明确失败、
  不返回部分结果，新 Service generation 递增并恢复签名；
- 目标 QE GPU Service 的 SIGKILL 连续三轮成功，实际触发 Segment crash
  recovery；共享内存 epoch 重建后 generation 重置，但新 PID、完整 worker
  pool、启动日志和 GPU 签名均恢复；
- 最终使用 Cloudberry fast shutdown 正常停止 Coordinator 和两个 Segment，
  `Segments with errors during stop = 0`。

因此，前置设计文档中“真实 GPU 验收待完成”的状态已经在本次单机、单 GPU、
1 QD + 2 Primary、无 Mirror 环境下完成。

这个结论仍不等于生产就绪。本阶段没有证明多主机、Mirror/FTS、CUDA fatal、
主机级 GPU 资源隔离、并发压力、长时间稳定性或性能收益，也没有开放 ORCA、
AO/AOCO、分区表、GpuJoin、GpuPreAgg、GpuSort、GpuCache、GPU-Direct 或 DPU。

## 2. 与前置里程碑的关系

`CLOUDBERRY_GPUSCAN_MVP_DESIGN.md` 记录了单 Primary GpuScan 的底层移植：

1. Cloudberry PostgreSQL planner/executor API 适配；
2. MPP locus、成本、Motion 和 QD-to-QE CustomScan 重写；
3. GpuScan-only 能力裁剪；
4. GPU Service worker 生命周期；
5. GpuCache 未初始化状态隔离；
6. host/device 32KB storage config 同步；
7. 普通分布式 heap 与负向边界。

`CLOUDBERRY_GPUSCAN_MULTI_SEGMENT_MILESTONE.md` 随后证明了上述实现能够在
单机两个 Primary QE 上正确运行，并完成受控 SIGHUP 故障传播与恢复。

本阶段不扩大 GpuScan 支持的 SQL、表类型和算子范围，重点补齐三个方面：

- 每个 QD/QE GPU Service 的 SQL 可观测性；
- SQL query cancel 后的资源排空与结果恢复；
- SIGHUP 与 SIGKILL 两种不同 shared-memory 生命周期下的自动验收。

## 3. 里程碑出口与最终状态

| 编号 | 出口 | 状态 | 主要证据 |
|---|---|---|---|
| 1 | QD 和所有 Primary 均能报告完整 GPU Service 状态 | 通过 | `pgstrom.gpu_service_status` 返回 content `-1/0/1` 三行，全部 ready、16/16 workers |
| 2 | query cancel 后 QE client/queue/active 归零 | 通过 | 三轮均显示 commands terminal、queues drained、signature recovered |
| 3 | SIGHUP 后新 PID/generation/worker/signature 恢复 | 通过 | 三轮 generation `1→2→3→4`，worker 日志 `1→2→3→4` |
| 4 | SIGKILL 后无部分结果且 Segment 自动恢复 | 通过 | 三轮新 PID、worker 日志 `5→6→7→8`、签名恢复，epoch reset 被明确识别 |
| 5 | 原多 Segment 正确性和安全回退不退化 | 通过 | `run_demo.sh` 的三类签名、计划和负向场景通过 |
| 6 | 静态边界和脚本语法检查通过 | 通过 | `test_static_mvp.sh`、`bash -n`、`git diff --check` 通过 |

## 4. GPU Service SQL 可观测性

### 4.1 扩展版本和 SQL 放置

Cloudberry PG-Strom extension 默认版本由 6.0 升至 6.1，并增加升级脚本：

```text
src/sql/pg_strom--6.0--6.1.sql
```

SQL 接口分为三个层次：

- `pgstrom.gpu_service_status_local()`：`EXECUTE ON COORDINATOR`；
- `pgstrom.gpu_service_status_segments()`：`EXECUTE ON ALL SEGMENTS`；
- `pgstrom.gpu_service_status`：合并 Coordinator 和所有 Segment 结果。

C 函数只读取当前 postmaster 的 shared memory，不在扩展内部自行连接其他
实例。MPP dispatch 由 Cloudberry SQL function placement 完成。

### 4.2 状态字段

每个 GPU device 返回：

- `content_id`；
- `postmaster_pid`；
- `service_pid`；
- `service_generation`；
- `ready`；
- `gpu_id`、`device_name`；
- `configured_workers`、`actual_workers`；
- `active_clients`；
- `queued_commands`、`active_commands`；
- `submitted_commands`、`completed_commands`；
- `failed_commands`、`cancelled_commands`；
- `fatbin_name`；
- `device_config`。

`content_id=-1` 表示 Coordinator；非负值表示对应 Primary content。
`ready` 不只读取共享布尔值，还验证共享 PID 当前是否存活，降低 SIGKILL 后
旧 ready 状态误导监控的概率。

### 4.3 counter 语义

命令进入 GPU context queue 时：

- `queued_commands` 增加；
- `submitted_commands` 增加。

worker 取出命令后：

- `queued_commands` 减少；
- `active_commands` 在执行窗口内增加，结束后减少。

最终按结果进入：

- `completed_commands`；
- `failed_commands`；
- `cancelled_commands`。

`cancelled_commands` 统计 GPU Service command，而不是 SQL statement。SQL
cancel 如果发生在当前 GPU command 已经完成之后，该计数可以不增长。

### 4.4 shared-memory epoch

`gpuServSharedState` 位于 postmaster shared memory。

在同一个 shared-memory epoch 内，受控 GPU Service background-worker 重启
会保留 generation 和累计 command counter；新进程只重置 PID、ready、
worker、queue、active 和 client 等当前代际状态。

如果 `BGWORKER_SHMEM_ACCESS` 的 GPU Service 被 SIGKILL，PostgreSQL/Cloudberry
可能让 Segment postmaster 执行 crash recovery 并重建 shared memory。此时：

- postmaster 监督进程 PID 可以保持不变；
- shared-memory epoch 改变；
- generation 和累计 counter 从新 epoch 的初始值重新计数；
- 不能把新旧 epoch 的 generation 做单调大小比较。

这是本次真实 SIGKILL 验收发现并固化到 runner 和文档中的重要边界。

## 5. Query cancel runner 的演进

### 5.1 初始问题：瞬时 gauge 无法稳定采样

最初的 `run_query_cancel.sh` 要求在同一次分布式 status 查询中观察到：

```text
submitted 增长
queued + active > 0
active_clients > 0
```

Tesla T4 上单个 GPU command 很快，`queued`、`active` 和 `client` 都是瞬时
gauge。一次 `gpu_service_status_segments()` 自身还需要 QD-to-QE dispatch，
所以 GPU command 可能在相邻两次采样之间完成。

实际失败状态类似：

```text
97|95|0|2|0|0|0|t
```

这表示累计命令已经进入终态且 Service ready，但脚本没有采到短暂的 busy
窗口。延长 timeout 不能解决采样窗口问题。

最终同步点改为单调递增的 `submitted_commands`：只要目标 QD backend 仍是
active 且 submitted 相对 idle baseline 增长，就证明本轮已经到达 GPU
Service，并立即调用 `pg_cancel_backend()`。瞬时 gauge 继续记录为诊断信息，
但不再作为取消前置条件。

### 5.2 初始负载问题：LATERAL 被 Materialize

原始目标查询声称会执行重复参数化 GpuScan，但实际计划为：

```text
Nested Loop
  -> Function Scan generate_series(...)
  -> Materialize
       -> Aggregate
            -> Result
                 Filter: t.grp = (p.grp % 900)
                 -> Materialize
                      -> Gather Motion 2:1
                           -> Custom Scan (GpuScan)
```

GpuScan 只执行一次，其输出被 Materialize；之后 100000 次循环主要在 CPU 上
过滤缓存。即使设置 `enable_material=off`，Cloudberry 仍会为该相关 Motion
路径保留必要的 Materialize，因此不能依赖 planner GUC 强制重复 GpuScan。

最终 runner 改为：

1. 单独 `EXPLAIN` 每轮 SQL，确认包含 `Custom Scan (GpuScan)`；
2. 在一个带唯一 `application_name` 的 QD backend 中启动 PL/pgSQL `DO` 循环；
3. 每轮独立执行一条分布式 GpuScan 聚合 SQL；
4. 等待 submitted counter 增长；
5. 对仍 active 的同一个 backend 调用 `pg_cancel_backend()`。

独立 SQL 执行边界保证每轮重新进入 GpuScan，不依赖 correlated plan 的 rescan
和 Materialize 行为。

### 5.3 取消后的严格检查

每轮取消后 runner 仍要求：

- 后台 `psql` 非零退出；
- 客户端错误包含 query cancellation；
- 本轮所有新增 submitted command 都进入 completed、failed 或 cancelled
  terminal counter；
- `queued_commands=0`；
- `active_commands=0`；
- `active_clients=0`；
- Service 继续 ready 且实际 worker 数等于配置值；
- 新 GPU 查询签名重新等于 CPU baseline。

runner 还要求每轮开始时验收集群处于 idle，避免其他 PG-Strom 查询污染全局
counter 增量和归零条件。

## 6. SIGHUP 与 SIGKILL 验收语义

### 6.1 安全定位与显式授权

`run_failure_recovery.sh` 只支持单主机验收，并通过以下步骤定位目标：

1. 从 `gp_segment_configuration` 读取 content、host、port、dbid 和 datadir；
2. 从目标 datadir 的 `postmaster.pid` 读取并验证 postmaster；
3. 只在该 postmaster 的直属子进程中查找唯一的
   `PG-Strom GPU Service`；
4. 信号只发送给该唯一 Service PID。

SIGHUP 要求：

```text
PGSTROM_MVP_ALLOW_SERVICE_RESTART=1
```

SIGKILL 还要求第二重授权：

```text
PGSTROM_MVP_ALLOW_HARD_FAILURE=1
```

### 6.2 SIGHUP：同 epoch 受控重启

PG-Strom 的 SIGHUP handler 先清除 ready，关闭 socket、GPU context 和 worker，
再以非零状态退出。postmaster 按 `bgw_restart_time=5` 创建新 Service。

shared memory 没有重建，因此 runner 严格要求：

- 新 Service PID 不同；
- `new_generation > old_generation`；
- ready 且 `actual_workers=configured_workers`；
- worker startup 日志新增；
- GPU 签名恢复。

### 6.3 SIGKILL：允许新 shared-memory epoch

SIGKILL 属于 hard failure。GPU Service 来不及执行正常 cleanup，并可能触发
Segment crash recovery。

runner 不再错误要求跨 epoch generation 递增，而是要求：

- 旧 PID 确实退出；
- 故障窗口内分布式查询失败且没有部分结果；
- 原 Segment postmaster 监督进程仍存在；
- 出现不同的新 GPU Service PID；
- SQL status 显示 ready/full worker；
- worker startup 日志增加；
- 恢复 GPU 签名等于 CPU baseline。

若 `new_generation <= old_generation`，runner 输出：

```text
(shared-memory epoch reset after SIGKILL)
```

该标记不是放宽功能正确性，而是说明新旧 generation 属于不同 shared-memory
生命周期，应该使用 PID、ready worker、日志和签名组成恢复证据。

## 7. GPU 验收环境

### 7.1 软件与硬件

```text
OS:             openEuler 24.03 (LTS)
GPU:            NVIDIA Tesla T4, 15360 MiB
Driver:         550.144.03
CUDA capability reported by driver: 12.4
CUDA Toolkit:   12.4 Update 1
PG-Strom extversion: 6.1
Cloudberry:     3.0.0-devel build dev
```

openEuler 使用 `dnf` 安装 Cloudberry 构建依赖。CUDA 使用 NVIDIA
distribution-independent runfile，只安装 Toolkit，不覆盖已有 driver。

### 7.2 集群拓扑

```text
Coordinator: content -1, port 7000
Primary 0:  content 0,  port 7002
Primary 1:  content 1,  port 7003
Mirror:     none
Standby:    none
Host:       7b92645df2a9
GPU:        三个 postmaster Service 共享同一块 Tesla T4
```

GPU Service 配置：

```conf
shared_preload_libraries = 'pg_strom'
max_worker_processes = 16
pg_strom.gpu_mempool_segment_sz = '256MB'
pg_strom.gpu_mempool_max_ratio = 0.20
pg_strom.cpu_fallback = off
pg_strom.enabled = on
pg_strom.enable_gpuscan = on
```

### 7.3 fatbin 与 device config

QD 和两个 QE 均返回：

```text
device_name: Tesla T4
configured_workers: 16
actual_workers: 16
ready: true
fatbin: .pgstrom_fatbin/pgstrom-gpucode-V012040-32172fbfacbac2689620c930889dce96.fatbin
device_config: NAMEDATALEN=64,BLCKSZ=32768,RELSEG_SIZE=32768,
               PG_PAGE_LAYOUT_VERSION=14,MAXIMUM_ALIGNOF=8
```

这证明 runtime fatbin 使用 CUDA 12.4，并与 Cloudberry 32KB heap page 配置一致。

## 8. 多 Segment 正确性回归

`run_demo.sh` 检测到两个正常 Preferred Primary：

```text
Cloudberry PG-Strom topology: 2 up preferred primary segments
```

数据分布：

```text
uniform heap: 0:1000278,1:999722
skew heap:    1:300000
small heap:   1:16
```

三类计划均包含：

```text
Gather Motion 2:1  (slice1; segments: 2)
  -> Custom Scan (GpuScan)
       Scan-Engine: VFS with GPU0
```

CPU 和三轮 GPU 签名分别为：

```text
uniform:
107000|109637978000|79879780.00|43384fb5927e97c4f616dd5846cc13b1

skew:
94250|15350054875|12124844|27450548.75|7250|5545|f6d6efd818c679ab4ff488a246c3c1d1

small:
16|136|-8|-10.00|5|3|0a64ee7ff4407f33b7c3ef92c49a94c4
```

LIMIT、prepared statement、参数变化、重复执行、负数、NULL、text/numeric
投影继续通过；ORCA、AO/AOCO、分区和 host-only 条件继续使用原生计划。

## 9. Query cancel 三轮实测

基线签名：

```text
107000|109637978000|79879780.00
```

三轮结果：

```text
cycle 1: submitted=12 terminal=12 completed=12 failed=0 cancelled=0
cycle 2: submitted=12 terminal=12 completed=12 failed=0 cancelled=0
cycle 3: submitted=12 terminal=12 completed=12 failed=0 cancelled=0
```

每轮均满足：

- QD backend 被 `pg_cancel_backend()` 成功取消；
- `sampled_client=1`，证明目标 backend 已连接 GPU Service；
- `sampled_busy=0`，说明没有采到短暂 queued/active 窗口，但不影响 monotonic
  submitted 同步证据；
- 12 个新增 GPU commands 全部进入 terminal 状态；
- queue、active、client 全部归零；
- 恢复签名正确。

`cancelled=0` 表示 SQL cancel 到达时，已提交的 GPU commands 恰好都已完成，
取消发生在相邻命令或 PL/pgSQL 循环边界。这证明 query cancellation、资源清理
和后续恢复，但不单独证明某个正在执行的 CUDA kernel 被中途终止。

最终输出：

```text
GpuScan query cancellation passed for 3 cycles.
```

## 10. SIGHUP 三轮实测

故障目标：

```text
content=0
dbid=2
port=7002
postmaster pid=158842
configured workers=16
```

Service PID 和 generation：

```text
cycle 1: pid 158853 -> 177690, generation 1 -> 2
cycle 2: pid 177690 -> 177984, generation 2 -> 3
cycle 3: pid 177984 -> 178292, generation 3 -> 4
```

worker startup 日志计数：

```text
1 -> 2 -> 3 -> 4
```

每轮 Service 不可用期间，分布式查询都返回预期错误：

```text
failed on connect('.pg_strom.158842.gpuserv.sock'):
No such file or directory (seg0 slice1 ...)
```

查询没有输出部分结果标记，每轮恢复后的 GPU 签名都重新等于 CPU baseline。

最终输出：

```text
GPU Service SIGHUP failure propagation and recovery passed for 3 cycles on content 0.
```

## 11. SIGKILL 三轮实测

同一个 content 0 Segment 上的三轮 Service PID：

```text
cycle 1: 178854 -> 180907
cycle 2: 180907 -> 181180
cycle 3: 181180 -> 181452
```

每轮均观察到：

```text
status generation 2 -> 2
(shared-memory epoch reset after SIGKILL)
```

worker startup 日志计数：

```text
5 -> 6 -> 7 -> 8
```

每轮均满足：

- SIGKILL 只发送给目标 GPU Service；
- 旧 Service PID 退出；
- 分布式查询失败且没有部分结果；
- 原 postmaster 监督进程 PID `158842` 保持存在；
- crash recovery 后出现新 Service PID；
- 新 status ready 且 worker 数为 16/16；
- 新 worker startup 日志出现；
- GPU 签名恢复。

最终输出：

```text
GPU Service SIGKILL failure propagation and recovery passed for 3 cycles on content 0.
```

该结果验证的是 `BGWORKER_SHMEM_ACCESS` Service hard failure 和 Segment crash
recovery，不等价于 CUDA fatal、整个 Segment 进程 SIGKILL、Mirror failover 或
多主机故障转移。

## 12. 验收过程中发现的问题

### 12.1 首次启动 readiness 竞态

新环境第一次运行 `run_demo.sh` 时曾返回：

```text
GPU Service status is incomplete or unready: 2|1|f|3
```

随后三行 status 全部变为 ready，PID 和 generation 保持稳定。这证明不是
Service crash，而是首次 fatbin/worker 初始化尚未完成时 runner 做了单次
即时检查。

当前结论不受影响，但 `run_demo.sh` 后续应增加带 timeout 的 readiness 轮询，
避免 cold start 偶发误报。

### 12.2 旧 cancel runner 遗留 backend

早期 LATERAL runner 失败退出时只终止了本地 `psql`，一个服务端 backend
继续执行已经 Materialize 的 CPU 密集查询。最终 `gpstop -a` 的 smart mode
等待该会话两分钟后提示：

```text
application_name='pgstrom_mvp_cancel_164977'
```

选择 fast mode 后，Cloudberry 终止遗留会话并正常关闭全部实例：

```text
Segments stopped successfully    = 2
Segments with errors during stop = 0
Database successfully shutdown with no errors reported
```

遗留 backend 来自已被替换的旧负载，不影响最终三轮新 runner 结果。但异常
cleanup 路径仍应进一步加固：trap 中应优先取消已定位的服务端 backend，必要时
再终止本地 `psql`，避免测试失败时遗留长查询。

### 12.3 generation 不能跨 crash-recovery epoch 比较

第一版 SIGKILL runner 要求 `new_generation > old_generation`，实际得到：

```text
old=4 new=2
```

此时新 PID、ready/full worker 和签名已经恢复，真正失败的是 runner 的状态
模型。修复后只对 SIGHUP 的同 epoch 重启要求 generation 单调递增；SIGKILL
若触发 shared-memory 重建，则用新 PID、worker 日志、ready 状态和恢复签名
验收，并明确打印 epoch reset。

## 13. 当前能力边界

| 维度 | 当前状态 | 说明 |
|---|---|---|
| 集群拓扑 | 已验收单机 1 QD + 2 Primary | 无 Mirror/Standby，三个 Service 共享一块 T4 |
| 多主机 | 未验收 | process-level failure runner 明确拒绝远程目标 |
| Service status | 已验收 | QD 与所有 Primary 通过 SQL 聚合展示 |
| Query cancel | 三轮通过 | 验证 SQL cancel、Service 排空和签名恢复 |
| in-flight CUDA kernel cancel | 未单独证明 | 本次 commands 在 SQL cancel 前均已 completed |
| SIGHUP | 三轮通过 | 同 epoch PID/generation/worker/signature 恢复 |
| SIGKILL | 三轮通过 | 允许 Segment crash recovery 和 shared-memory epoch reset |
| CUDA fatal | 未验收 | 不由 Service SIGKILL 结果外推 |
| Mirror/FTS | 未验收 | 未配置 Mirror，不验证接管或角色切换 |
| 表类型 | 普通分布式 heap | AO/AOCO/分区继续回退 |
| Planner | PostgreSQL planner，`optimizer=off` | ORCA 不生成 GpuScan |
| 条件 | 完整 device qual | host-only/混合 qual 继续回退 |
| CPU fallback | 故障验收时关闭 | 避免 GPU/Service 错误被掩盖 |
| 并发资源隔离 | 未实现 | 每个 postmaster 独立维护 GPU memory pool |
| 性能 | 不形成结论 | `enable_seqscan=off` 的正确性验收不是 benchmark |
| 高级算子 | 未开放 | GpuJoin/GpuPreAgg/GpuSort/GpuCache 等不在范围内 |

## 14. Commit 演进

### 14.1 `48c2b2badbf` — GPU Service 可观测性与恢复验收基础

主要内容：

- extension 版本升级到 6.1；
- 新增 QD/Segment SQL status function 和统一 view；
- 增加 Service PID、generation、ready、worker、client、command counters、
  fatbin 和 device config；
- command 生命周期计数；
- query cancel runner；
- guarded SIGKILL fault injection；
- 设计文档、README 和静态检查。

### 14.2 `c8fe572d5d8` — Query cancel terminal 判定修复

取消后的成功条件改为本轮所有 submitted commands 都进入 completed、failed
或 cancelled 终态，不再错误要求每轮 `cancelled_commands` 必须增长。

### 14.3 `55ae567032c` — Query cancel 采样稳定化

- 识别 queued/active/client 是瞬时 gauge；
- 以 submitted 单调增量作为稳定同步点；
- 增加 idle baseline；
- 保留瞬时状态作为诊断输出；
- 严格保留 terminal、drain 和 signature 检查。

该提交最初还尝试用 `enable_material=off` 消除 correlated plan 的缓存，真实
Cloudberry 计划证明该假设不成立，随后由下一提交替换负载模型。

### 14.4 `de622ae6bb2` — 使用服务端循环保证重复 GpuScan

- 删除 correlated LATERAL 取消负载；
- 单独验证每轮 SQL 包含 GpuScan；
- 在同一 QD backend 内使用 PL/pgSQL `DO` 循环；
- 每轮独立执行分布式 GpuScan，避免跨轮 Materialize；
- 保留 submitted 同步和取消后恢复检查。

### 14.5 `1f1f40e2416` — SIGKILL shared-memory epoch 判定修复

- SIGHUP 继续要求 generation 严格递增；
- SIGKILL 下允许 crash recovery 后 generation 重置；
- epoch reset 时仍严格检查新 PID、ready/full worker、日志和签名；
- 更新设计文档和静态 guard。

## 15. 验收命令

### 15.1 多 Segment 正确性

```sh
PGDATABASE=pgstrom_mvp \
PGSTROM_MVP_REPEAT=3 \
./gpcontrib/pg_strom/cloudberry/demo/run_demo.sh
```

### 15.2 Query cancel

```sh
PGDATABASE=pgstrom_mvp \
PGSTROM_MVP_CANCEL_CYCLES=3 \
PGSTROM_MVP_CANCEL_TIMEOUT=30 \
./gpcontrib/pg_strom/cloudberry/demo/run_query_cancel.sh
```

### 15.3 SIGHUP

```sh
PGDATABASE=pgstrom_mvp \
PGSTROM_MVP_ALLOW_SERVICE_RESTART=1 \
PGSTROM_MVP_SERVICE_SIGNAL=HUP \
PGSTROM_MVP_TARGET_CONTENT=0 \
PGSTROM_MVP_RECOVERY_CYCLES=3 \
PGSTROM_MVP_RECOVERY_TIMEOUT=30 \
./gpcontrib/pg_strom/cloudberry/demo/run_failure_recovery.sh
```

### 15.4 SIGKILL

```sh
PGDATABASE=pgstrom_mvp \
PGSTROM_MVP_ALLOW_SERVICE_RESTART=1 \
PGSTROM_MVP_ALLOW_HARD_FAILURE=1 \
PGSTROM_MVP_SERVICE_SIGNAL=KILL \
PGSTROM_MVP_TARGET_CONTENT=0 \
PGSTROM_MVP_RECOVERY_CYCLES=3 \
PGSTROM_MVP_RECOVERY_TIMEOUT=45 \
./gpcontrib/pg_strom/cloudberry/demo/run_failure_recovery.sh
```

### 15.5 静态检查

```sh
bash -n gpcontrib/pg_strom/cloudberry/demo/run_demo.sh
bash -n gpcontrib/pg_strom/cloudberry/demo/run_query_cancel.sh
bash -n gpcontrib/pg_strom/cloudberry/demo/run_failure_recovery.sh
gpcontrib/pg_strom/cloudberry/test_static_mvp.sh
git diff --check
```

## 16. 下一阶段建议

建议先完成当前 runner 的工程化收尾，再扩大功能范围：

1. 为 `run_demo.sh` 增加 GPU Service cold-start readiness timeout 和逐 content
   超时诊断；
2. 为 cancel runner 的 trap 增加服务端 backend cancel/terminate 清理，保证
   任何失败路径都不遗留查询；
3. 如果必须证明 active GPU command 被中途取消，增加单调 command-start
   事件或测试同步点，而不是依赖瞬时 active gauge；
4. 增加数小时 cancel/HUP/KILL 循环，检查 backend、socket、pthread、CUDA
   context 和显存泄漏；
5. 建立主机级 GPU resource accounting，再进行多会话并发验收；
6. 扩展到多主机、每台独立 GPU 的多 Segment GpuScan；
7. 单独设计 Mirror/FTS 和 Segment postmaster 故障矩阵；
8. 单独注入 CUDA API/device fatal，不能以 Service SIGKILL 代替；
9. 在正确性与恢复边界稳定后，再分别评估 AO/AOCO、分区、host quals 和其他
   GPU 算子。

## 17. 推荐版本定位

对外描述建议使用：

> Cloudberry PG-Strom v6.1 multi-segment GpuScan observability and recovery
> technical milestone：在 PostgreSQL planner 下支持普通分布式 heap 表，已在
> openEuler 24.03、Tesla T4、单机 1 QD + 2 Primary 环境完成多 Segment
> CPU/GPU 正确性、SQL Service 状态、三轮 query cancel、三轮受控 SIGHUP 以及
> 三轮 SIGKILL/Segment crash recovery 验收；不包含多主机、Mirror/FTS、
> CUDA fatal、并发资源隔离、性能结论、ORCA、AO/AOCO、分区表和其他
> PG-Strom 加速算子，尚非生产就绪版本。

## 18. 相关文件

- `CLOUDBERRY_GPUSCAN_MVP_DESIGN.md`：单 Primary MVP 底层设计与 commit 演进；
- `CLOUDBERRY_GPUSCAN_MULTI_SEGMENT_MILESTONE.md`：双 Primary 正确性与受控
  SIGHUP 前置里程碑；
- `CLOUDBERRY_GPUSCAN_OBSERVABILITY_RECOVERY_DESIGN.md`：本阶段进入 GPU
  验收前的设计与出口；
- `CLOUDBERRY.md`：Cloudberry 集成构建方式和能力边界摘要；
- `cloudberry/demo/README.md`：构建、集群、状态和验收命令；
- `cloudberry/demo/run_demo.sh`：多 Segment 正确性与负向边界；
- `cloudberry/demo/run_query_cancel.sh`：query cancel 与排空恢复验收；
- `cloudberry/demo/run_failure_recovery.sh`：SIGHUP/SIGKILL 故障传播与恢复；
- `cloudberry/test_static_mvp.sh`：实现边界与 runner 静态 guard；
- `src/gpu_service.c`：shared status、command counters、Service 生命周期；
- `src/sql/pg_strom--6.0--6.1.sql`：SQL 可观测性升级接口；
- `src/pg_strom.control`：extension 6.1 默认版本。
