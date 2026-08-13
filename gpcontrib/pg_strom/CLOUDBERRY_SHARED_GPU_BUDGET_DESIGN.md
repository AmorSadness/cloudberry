# Cloudberry PG-Strom 单机共享 GPU 资源预算与并发安全设计

## 1. 状态与完成定义

核心资源门状态：**已完成代码、静态检查和真实单机共享 GPU 验收**。验收于
2026-08-13 在 1 coordinator + 2 Primary、三个 postmaster 共享一块 Tesla T4
的环境完成。

按 P0a/P0b/P0c 扩展清单补充的静态诊断、GpuScan 组合矩阵和受控 allocation
failure 也已完成代码、静态检查和真实 GPU 验收。因此 P0a、P0b、P0c 在本设计
限定的单机、同用户、同 PID namespace 拓扑下均已完成。

本 P0 面向当前可用拓扑：一个 coordinator 与多个 Primary Segment 位于同一
主机，各 postmaster 启动独立 GPU Service，并共享同一块物理 GPU。它不依赖、
也不证明多主机或每主机独立 GPU 的行为。

完成定义及本次验收结论如下：

1. 两个以上 Segment 并发执行 GpuPreAgg 时，所有 GPU Service 看到相同的主机级
   `shared_budget_bytes`，且 `shared_reserved_bytes` 不超过该值；
2. 预算充足的查询与 CPU baseline 一致；预算不足时在超时内明确失败，不出现
   Service crash、CUDA OOM 风暴或部分聚合结果；
3. 查询正常结束、SQL cancel、客户端断连后 `local_reserved_bytes` 回到基线；
4. GPU Service 被 SIGKILL 后，其他 Service 能回收死进程账目并继续 admission，
   `stale_reclaims` 增长；
5. M1–M4a、cancel 与 failure-recovery runner 最终回归通过。

上述五项均已满足；本结论仅覆盖同一主机、同一 OS 用户、同一 PID namespace
内的共享 GPU，不外推到多主机、容器跨 PID namespace、资源组公平性或性能收益。

## 2. 问题

原有 `pg_strom.gpu_mempool_max_ratio` 是单 GPU Service 的本地上限。Cloudberry
的每个 Segment 是独立 postmaster，因此 PostgreSQL shared memory、memory pool
及上限都不跨 Segment。两个 Service 都配置 20% 并不代表主机总共 20%，而是
各自最多 20%。此外，GpuPreAgg final buffer 使用直接 `cuMemAllocManaged()`，
原先完全绕过 memory-pool 上限。

M4a 提供了结构化规划估算，但 planner estimate 不能替代执行时 admission：并发
查询可能分别合法，合计却超过同一块卡的安全容量；GpuPreAgg 扩容还会短暂同时
持有旧、新两个 buffer。

## 3. 设计目标与边界

目标：

- 以物理 GPU UUID 为隔离键，在同一 OS 用户的所有 postmaster 间共享预算；
- CUDA 分配发生前原子预留，避免 check-then-allocate 竞态；
- 对暂时不足提供有界等待，对持续不足明确拒绝；
- 正常结束、取消、断连、SIGHUP 和 SIGKILL 都不会永久泄漏额度；
- 从 `pgstrom.gpu_service_status` 同时观察主机总额度与本 Service 占用。

本阶段纳入预算的对象：

- raw/managed GPU memory pool 新 segment 的完整物理 allocation；
- GpuJoin/GpuPreAgg 共用 query buffer 中的 final、aggregation、projection 与
  fallback allocation；
- GpuPreAgg 扩容期间新旧 buffer 同时存在的峰值。

CUDA module/driver 内部开销及 GpuCache 的独立常驻 allocation 尚未统一计入，
因此默认预算最多为物理显存的 80%，保留至少 20% 给驱动、context、kernel 和
未纳入账目的开销。本 P0 是 PG-Strom Service allocation 的主机级硬门，不是
Cloudberry resource group 的用户级公平调度器。

### 3.1 P0a/P0b/P0c 对照

- **P0a 静态主机预算**：账本统计同 GPU UUID 的 live Service；分别显示单
  Service 配额、配额理论和、物理容量、安全余量、安全容量与超配状态。实际 gate
  不超过 `physical - safety_margin`，理论配额和超限时 GPU Service 写 warning；
- **P0b admission/backpressure**：M4a estimate 构造 session final-buffer，Service
  按相同字节数申请额度；SQL 的 `last_request_bytes/max_request_bytes` 可核对申请，
  不足时有界等待后安全失败，cancel/error/断连/SIGKILL 均释放或回收；
- **P0c 并发验收**：既有多 GpuPreAgg、cancel、SIGKILL 用例之外，6.3 runner
  新增 GpuScan+GpuScan、GpuScan+GpuPreAgg，以及 reservation 后、CUDA 前的受控
  allocation failure，要求无泄漏、无部分结果且后续查询恢复。

## 4. 跨 postmaster 共享账本

每块物理 GPU 使用一个 POSIX shared-memory object：

```text
/pgstrom-gpu-budget-<euid>-<normalized GPU UUID>
```

`euid` 防止不同系统用户互相占用账本；GPU UUID 保证同一块物理卡即使在各
postmaster 中拥有不同 device index，仍落到同一个账本。对象权限为 `0600`。

账本包含：

- magic、协议版本和物理显存大小，用于拒绝 ABI 或设备不一致；
- process-shared robust mutex，序列化检查、预留、释放和回收；
- 最多 128 个 GPU Service owner slot，记录 PID、Linux `/proc` start time、配置
  预算和已预留字节；
- admission、rejection、wait、stale reclaim 累计计数。

初始化使用文件锁保护，magic 最后发布。持锁进程异常死亡时，下一个调用者通过
robust mutex 取得所有权并修复锁状态。每次 admission/释放还会结合
`kill(pid, 0)` 与 `/proc/<pid>/stat` start time 清扫已经死亡或 PID 已复用的 GPU
Service；其 reservation 与 waiter 一并回收。

账本不在最后一个 Service 退出时 `shm_unlink()`，以保留跨 Service 重启的诊断
计数。新版本若改变共享结构，必须增加协议版本；不兼容对象会使 GPU Service
明确启动失败，不能静默解释旧布局。

## 5. Admission 算法

每个存活 Service owner 发布：

```text
configured_budget = physical_device_bytes * shared_gpu_budget_ratio
effective_budget  = min(configured_budget of all live owners)
```

采用最小值使配置滚动变更保持保守：不同 Segment 暂时配置不一致时，不会因为
较宽松的 Service 放大整机上限。

分配 `N` 字节前，在共享 mutex 内执行：

```text
reclaim dead owners
if N <= effective_budget - sum(live reservations):
    current owner reservation += N
    admit
else:
    wait up to shared_gpu_budget_timeout, then reject
```

锁只保护账本，不包围 CUDA API。预留成功、CUDA allocation 失败时立即回滚；
释放顺序是先完成 `cuMemFree()`，再归还预算，避免另一个 Service 在显存实际尚未
释放时被提前放行。

GpuPreAgg 扩容需要先预留完整的新 buffer，再分配和复制，最后释放旧 buffer 并
归还旧额度。因此账目覆盖扩容峰值。若峰值无法 admission，查询明确失败，旧
buffer 在 query cleanup 路径释放。

## 6. 配置

以下 SIGHUP 级 GUC 修改并 reload 后，GPU Service 按现有 SIGHUP 重启
流程应用新值：

| GUC | 默认值 | 范围 | 含义 |
|---|---:|---:|---|
| `pg_strom.shared_gpu_budget_ratio` | `0.80` | `0.10..0.95` | 每块物理 GPU 可供受控 PG-Strom allocation 使用的比例 |
| `pg_strom.shared_gpu_safety_margin_ratio` | `0.20` | `0.05..0.80` | 为 CUDA context、module/fatbin、GpuCache 和未跟踪占用保留的主机比例 |
| `pg_strom.shared_gpu_budget_timeout` | `5s` | `0..600s` | admission 最大等待时间；`0` 为立即拒绝 |

单机多 Segment demo 使用更保守的 `0.20`，以便在共享 GPU 上验证 admission。
该 ratio 是主机总预算，不再乘以 Segment 数。`gpu_mempool_max_ratio` 仍控制单个
raw pool 的局部上限，但任何新 pool segment 还必须通过主机级 gate。

## 7. 生命周期与并发安全

- Service 启动：按 GPU UUID attach，清扫 stale slot，注册自己的 owner；
- 分配成功：allocation metadata 同时保存 device index、长度和类型；
- 正常释放：依据原 device index 归还对应物理 GPU 的额度；
- query cancel/客户端断连：既有 `gpuClientPut()` → `putGpuQueryBuffer()` 引用计数
  路径最终释放全部 allocation；
- 多客户端共享同一 `query_plan_id`：`gpuQueryBuffer.refcnt` 保证只对真实 CUDA
  allocation 记一次账；
- Service SIGHUP/正常退出：移除 owner slot，其剩余额度一次性归零；
- Service SIGKILL：下一个访问账本的 Service 发现 PID 不存在后回收；
- mutex owner SIGKILL：robust mutex 防止账本永久死锁。

bounded wait 位于每客户端独立 monitor thread，不阻塞 GPU Service 主 accept loop
或其他已建立客户端。等待采用短周期重试，超时后沿现有 XPU error 通道传播，
分布式查询不得返回部分结果。

## 8. SQL 可观测性与扩展升级

6.2 引入动态账本字段；6.3 继续增加静态预算和请求追踪字段：

| 列 | 含义 |
|---|---|
| `shared_budget_bytes` | 当前存活 owner 中最保守的主机级预算 |
| `shared_reserved_bytes` | 同 GPU UUID 所有存活 Service 的预留总和 |
| `local_reserved_bytes` | 当前行对应 GPU Service 的预留 |
| `budget_admissions` | 账本累计成功 admission |
| `budget_rejections` | 等待超时或立即拒绝累计数 |
| `budget_waits` | 至少等待过一次的 admission 累计数 |
| `stale_reclaims` | 回收死亡 Service slot 的累计次数 |
| `device_total_bytes` | 物理设备容量 |
| `host_service_count` | 同用户、同 GPU UUID 的存活 Service 数 |
| `service_budget_bytes` | 本 Service 发布的配置配额 |
| `host_configured_budget_sum` | 所有 live Service 配额的理论和 |
| `safety_margin_bytes` / `host_safe_capacity_bytes` | 静态安全余量及扣除后的容量 |
| `budget_overcommitted` | 理论配额和是否超过安全容量 |
| `last_request_bytes` / `max_request_bytes` | 本 Service 最近/最大 admission 请求 |

同一物理 GPU 的 host-wide 数值会出现在多个 Segment 行中，这是有意的：每行仍以
`content_id/postmaster_pid/service_pid` 标识本地 Service，而 host-wide 列应相同。
`local_reserved_bytes` 的和应等于任一新鲜行的 `shared_reserved_bytes`。
SQL C 函数直接锁定并读取 POSIX 账本，而不是只返回各 postmaster 的旧快照；读取
本身也可触发 stale owner 清扫。

升级命令：

```sql
ALTER EXTENSION pg_strom UPDATE TO '6.3';
```

## 9. 验收计划

静态/构建门：

- 共享键包含 euid 与 GPU UUID，mutex 为 process-shared robust；
- pool allocation、query buffer 与 GpuPreAgg expansion 三条路径均先 reserve；
- CUDA allocation/copy 失败路径回滚，新旧 buffer 替换后账目为新长度；
- 扩展 6.1→6.2→6.3 SQL 与 C tuple descriptor 列数、顺序一致。

真实 GPU 门：

1. idle 时记录所有 Service status，要求 `reserved <= budget`；
2. 并发启动至少三个强制 GpuPreAgg 查询，使总需求跨过 20% demo 预算；
3. 允许一部分查询成功，至少一个发生 wait 或 rejection；所有成功结果匹配 CPU；
4. 取消一个持有额度的查询，确认等待查询被放行或额度回到基线；
5. SIGKILL 一个持有额度的 GPU Service，确认其他 Service 触发 stale reclaim；
6. 最终要求 queue/active/client 排空、reservation 回到基线，并执行 M1–M4a 与
   M3 全量回归。

预算超时必须通过 XPU error 通道报告
`shared GPU budget admission rejected`。该错误发生在 CUDA allocation 之前，不得
伪装为 `CUDA_ERROR_OUT_OF_MEMORY`；并发 runner 一旦观察到真实 CUDA OOM 或其他
非预算错误，必须判定验收失败。

并发主路径 runner：

```sh
PGDATABASE=pgstrom_mvp \
PGSTROM_SHARED_BUDGET_CLIENTS=3 \
PGSTROM_SHARED_BUDGET_REQUIRE_REJECTION=1 \
./gpcontrib/pg_strom/cloudberry/demo/run_shared_gpu_budget.sh
```

扩展 P0a/P0c 矩阵：

```sh
PGDATABASE=pgstrom_mvp \
./gpcontrib/pg_strom/cloudberry/demo/run_shared_gpu_concurrency_matrix.sh
```

该 runner 要求静态预算不超配，分别并发执行 GpuScan+GpuScan 和
GpuScan+GpuPreAgg，然后由仅限 superuser 的 6.3 SQL hook 在预算预留成功后注入
一次 query-buffer allocation failure。注入不会调用 CUDA，不会主动耗尽整卡，
但覆盖与真实 allocation failure 相同的 reservation rollback 和查询错误清理路径。

### 9.1 真实 GPU 验收记录

验收配置为 `shared_gpu_budget_ratio=0.20`、timeout `5s`。Tesla T4 物理显存
15360MiB，对外状态显示主机预算 2984MiB；idle 常驻 reservation 为 512MiB，
两个 Segment 各 256MiB，coordinator 为 0。

- 24 客户端并发 GpuPreAgg：3 个查询成功且与 CPU baseline 一致，21 个查询在
  CUDA allocation 前收到明确的 `shared GPU budget admission rejected`；该轮
  观察到 46 次 wait、27 次 rejection，没有真实 `CUDA_ERROR_OUT_OF_MEMORY`，
  runner 输出 `shared GPU budget concurrent acceptance passed`；
- query cancel 连续三轮通过；每轮精确取消目标 backend，所有 submission 进入
  terminal 状态，client/queue/active 排空，恢复后的 signature 与 baseline 一致；
- content 0 GPU Service SIGKILL 连续三轮通过；故障窗口内分布式查询明确失败且
  没有部分结果，每轮 Service PID/worker 恢复，signature 一致；共享账本的
  `stale_reclaims` 从 0 增长到 3；
- 故障后所有 Service `ready=true`，`active_clients/queued_commands/active_commands`
  全部为 0，reservation 回到 512MiB 常驻基线；
- 最终 M1–M4a runner 的六类正向查询各连续三轮匹配 CPU baseline，负向矩阵均
  保持原生计划，输出 `Cloudberry Gather-only GpuPreAgg MVP acceptance passed`；
  回归结束后资源再次回到相同基线。

### 9.2 P0a/P0b/P0c 扩展矩阵验收记录

扩展 6.3 安装并升级后，`run_shared_gpu_concurrency_matrix.sh` 在同一套单机
1 coordinator + 2 Primary、共享 Tesla T4 的环境通过：

- GpuScan + GpuScan：两个结果均匹配 CPU baseline，结束后资源排空；
- GpuScan + GpuPreAgg：两个结果均匹配 CPU baseline，结束后资源排空；
- P0b request tracking：两个 Segment 均可观察到当时 planner-derived 1GiB
  GpuPreAgg admission request；
- 受控 allocation failure：预算预留后、CUDA 调用前注入失败，查询没有部分结果，
  reservation 精确回到注入前基线，随后 GpuPreAgg 与 CPU baseline 一致；
- runner 最终输出
  `Cloudberry shared-GPU P0a/P0c concurrency matrix passed`。

结合 9.1 已通过的 24 客户端多 GpuPreAgg、三轮 cancel、三轮 SIGKILL/stale
reclaim 和最终 M1–M4a 回归，原始清单中的 P0a 静态主机预算、P0b query
admission/backpressure、P0c 并发验收现均有真实 GPU 证据。

验收时还应同步采集 `nvidia-smi`，证明 SQL 账本上限与设备实际占用趋势一致；
由于 CUDA context 与 driver 开销不在账本内，两者不要求逐字节相等。

## 10. 已知限制与后续工作

- 当前 stale 判断基于同一 PID namespace 内的 `kill(pid, 0)`；容器跨 PID
  namespace 共享 GPU 时需要宿主机 broker 或 PID identity 扩展；
- 固定 128 owner slots 足以覆盖当前单机 demo，超出时 Service 明确拒绝启动；
- 未提供 FIFO/资源组公平性，大查询可能在持续小查询下等待至超时；
- GpuCache、CUDA module/context 及第三方 GPU 进程只依赖预留 headroom，不在账本；
- POSIX shared-memory 对象的协议升级需要运维确认旧 Service 已退出后清理旧对象；
- 多主机模式天然按 GPU UUID/主机内核 shared memory 分开，仍需独立验收。

P0a 静态诊断、P0b admission/backpressure、P0c 组合并发/故障回收现已全部完成
真实 GPU 验收。M4b 已把 grouped request 改为 16MiB 起步的自适应估算，并让
budget/matrix runner 使用 normal planner、检查最新请求小于 1GiB；该回归仍待真实
GPU 执行。多主机、资源组公平性、
GpuCache 统一计费和跨 PID namespace 协调仍需分别设计与验收。
