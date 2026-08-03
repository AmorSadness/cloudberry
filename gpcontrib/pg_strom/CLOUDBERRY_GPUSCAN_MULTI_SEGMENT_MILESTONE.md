# Cloudberry GpuScan 多 Segment 与故障恢复里程碑总结

> 文档基线：Cloudberry `main` 分支，HEAD `a5d5cb29896f54047ed42cc84892f7dc5a1f4f10`  
> 前置基线：单 Primary GpuScan MVP，commit `bdf71dbac91722c2455d25f58949ea5f18ff2cf8`  
> 上游基线：PG-Strom v6.1，commit `4d12ef415759dc48cd4c1421565e9c694b7bd3f9`  
> 验收日期：2026-08-03

> **后续开发说明**：本文是已经完成验收的多 Segment 基线。SQL Service
> 可观测性、自动 query cancel 和 SIGKILL 故障模型属于下一里程碑，设计及
> 待验收状态记录在 `CLOUDBERRY_GPUSCAN_OBSERVABILITY_RECOVERY_DESIGN.md`；
> 在 GPU 环境完成该文档出口前，不应把这些新增能力描述为已验收。

## 1. 结论

当前版本已经在原单 Primary GpuScan MVP 的基础上，完成了一个**单机、双 Primary、范围受控且包含 GPU Service 故障恢复验收的多 Segment 技术里程碑**。

实际 GPU 环境使用以下拓扑完成验收：

```text
1 Coordinator（QD，端口 7000）
2 Preferred Primary Segment（QE，端口 7002、7003）
0 Mirror
0 Coordinator Standby
1 台物理/容器主机，各数据库实例共享同一块 GPU
```

本阶段证明：

- QD 生成的 GpuScan 计划能以 `Gather Motion 2:1` 下发并在两个 QE 中执行；
- 均匀分布、单 Segment 倾斜和部分 QE 空扫描三种数据形状结果正确；
- `bigint`、`integer`、`numeric`、`text`、NULL 和负数投影结果正确；
- 三类查询的 CPU/GPU 稳定签名完全一致，并分别连续执行三轮；
- LIMIT、prepared statement、参数变化、重复执行和 lateral/rescan 继续可用；
- ORCA、AO、AOCO、分区表和 host-only 正则条件仍保持安全回退；
- 一个 QE 的 GPU Service 在受控退出期间，整条分布式查询明确失败且不返回部分结果；
- postmaster 自动创建新的 GPU Service，按配置重建 16 个 task worker，随后 GPU 查询签名恢复；
- 上述故障传播和恢复连续执行三轮成功，目标 Segment postmaster 始终存活。

因此，前一阶段文档中的“多 Segment 未验证”和“GPU Service 重启恢复仍需手工验证”两项限制，在**本次单机双 Primary、受控 SIGHUP 故障模型**下已经解除。

这个结论仍不等于生产就绪。当前没有证明多主机、Mirror/FTS 故障切换、跨进程 GPU 资源隔离、并发稳定性、SIGKILL/CUDA fatal 后的完整恢复、长时间运行或性能收益。

## 2. 与单 Primary MVP 的关系

本里程碑是 `CLOUDBERRY_GPUSCAN_MVP_DESIGN.md` 的后续阶段，不替代其中对底层实现的说明。

单 Primary MVP 已经完成：

1. PG-Strom v6.1 vendor 基线导入；
2. Cloudberry PostgreSQL 16 API/ABI 适配；
3. GpuScan-only 初始化和能力裁剪；
4. MPP locus、每 QE 成本和 Path 属性适配；
5. QD-to-QE CustomScan 表达式重写；
6. GpuCache 生命周期隔离；
7. GPU Service worker pool 重启重建；
8. host/device 32KB `BLCKSZ` 等存储配置同步；
9. 分区父表和叶子的双层阻断；
10. 单 Primary 的计划、结果签名和负向边界验收。

本阶段没有修改上述核心 C/CUDA 实现，而是扩展拓扑、数据矩阵、故障注入和可重复验收流程，验证原有 MPP 设计在两个 QE 上是否真实成立。

这一区分很重要：当前结果不是通过加入多 Segment 特判得到的，而是证明原有 locus、Motion、QD-to-QE 重写、每 QE executor 和独立 GPU Service 模型能够在双 Primary 拓扑下形成正确闭环。

## 3. 里程碑目标与出口

双方约定的五条出口及最终状态如下：

| 编号 | 里程碑出口 | 状态 | 主要证据 |
|---|---|---|---|
| 1 | 至少两个 Primary 的计划实际在 QE 上执行 GpuScan | 通过 | `Gather Motion 2:1 (segments: 2)` 下存在 `Custom Scan (GpuScan)` |
| 2 | 多种数据分布和参数场景 CPU/GPU 结果一致 | 通过 | 均匀、倾斜、小表三类签名各连续三轮一致；prepared/rescan 通过 |
| 3 | 任一 QE GPU Service 中断时整条查询明确失败且无部分结果 | 通过 | content 0 服务窗口期返回 `failed on connect(...)`，无结果标记输出 |
| 4 | Service 重启后 worker pool、ready 行为和查询自动恢复 | 通过 | 三轮 PID 代际变化、worker 日志递增、恢复签名一致 |
| 5 | 现有负向边界、静态检查和 GPU demo 不退化 | 通过 | ORCA/AO/AOCO/分区/正则均无 GpuScan；静态测试通过 |

## 4. 多 Segment 验收设计

### 4.1 动态拓扑判定

`run_demo.sh` 不再把计划形状固定为 `segments: 1`，而是从 `gp_segment_configuration` 动态读取：

- 配置的 Preferred Primary content 数；
- 当前 `role='p'`、`preferred_role='p'`、`status='u'` 的 content 数。

runner 只有在以下条件全部满足时才继续：

1. Preferred Primary 数量至少为 2；
2. 所有 Preferred Primary 均处于正常 Primary 角色；
3. 没有降级、Mirror 接管或缺失 content；
4. `EXPLAIN ANALYZE` 中 Motion 的 `segments: N` 与实际 Primary 数一致。

这避免了在降级拓扑下把“查询碰巧完成”误判为正常多 Segment 验收。

### 4.2 三类数据分布

#### 均匀分布表

`pgstrom_mvp_heap` 包含 2,000,000 行，以 `id` 为 distribution key。

实测分布：

```text
segment 0: 1,000,278 rows
segment 1:   999,722 rows
```

该场景验证两个 QE 都有实际输入时的并行扫描、Motion 汇总和全局结果签名。

#### 倾斜分布表

`pgstrom_mvp_skew` 包含 300,000 行，所有行使用同一个 distribution key。

实测分布：

```text
segment 0:       0 rows
segment 1: 300,000 rows
```

该场景验证一个 QE 执行实际 GPU 扫描、另一个 QE 执行空本地扫描时，计划和全局结果仍然正确。数据同时覆盖 NULL、负整数、负 numeric 和 text 投影。

#### 小表

`pgstrom_mvp_small` 仅包含 16 行，同样全部位于一个 Segment。

实测分布：

```text
segment 0:  0 rows
segment 1: 16 rows
```

该场景使用 `enable_seqscan=off` 强制暴露合法 GpuScan path，仅用于验证小输入和空 QE 的执行语义，不代表 GPU 对小表具有性能优势。

### 4.3 计划证据

三类查询均出现以下核心形状：

```text
Gather Motion 2:1  (slice1; segments: 2)
  ->  Custom Scan (GpuScan)
        GPU Projection: ...
        GPU Scan Quals: ...
        Scan-Engine: VFS with GPU0
```

这说明：

- GpuScan 位于 QE slice，而不是 QD 上的伪计划；
- Motion 的参与 Segment 数与实际拓扑一致；
- device qual 和 projection 由 GPU 执行；
- 倾斜和空输入不会让 CustomScan 从某个 QE 泄漏或改变为错误路径。

## 5. 结果正确性证据

### 5.1 均匀表签名

CPU 基线和三轮 GPU 执行均返回：

```text
107000|109637978000|79879780.00|43384fb5927e97c4f616dd5846cc13b1
```

### 5.2 倾斜表签名

CPU 基线和三轮 GPU 执行均返回：

```text
94250|15350054875|12124844|27450548.75|7250|5545|f6d6efd818c679ab4ff488a246c3c1d1
```

其中包括：

- 结果行数；
- `id`、`metric`、`amount` 聚合；
- NULL integer 数量；
- NULL text 数量；
- 按 `id` 排序后的内容摘要。

### 5.3 小表签名

CPU 基线和三轮 GPU 执行均返回：

```text
16|136|-8|-10.00|5|3|0a64ee7ff4407f33b7c3ef92c49a94c4
```

该结果同时证明小表中的负整数、负 numeric、NULL 和 text 投影没有发生 host/device 表示偏差。

### 5.4 参数、LIMIT 与 rescan

验收继续覆盖：

- `LIMIT 10000` 下双 QE GpuScan；
- prepared statement 的不同 integer/numeric 参数；
- 同一 prepared statement 重复执行；
- lateral 参数化执行/rescan 形状；
- bigint、integer、numeric、text 的组合结果。

所有查询正常完成，runner 最终返回码为 0。

## 6. GPU Service 故障传播设计

### 6.1 为什么使用独立 runner

普通正确性 demo 不应默认改变数据库后台进程。因此故障测试放在独立的 `run_failure_recovery.sh` 中，并要求显式设置：

```text
PGSTROM_MVP_ALLOW_SERVICE_RESTART=1
```

没有该授权变量，脚本在发送任何信号前退出。

### 6.2 目标进程的安全定位

故障 runner 不使用模糊的全局进程名匹配，而是：

1. 从 `gp_segment_configuration` 取得目标 content 的 host、datadir、port 和 dbid；
2. 拒绝远程主机，只支持本次单机里程碑；
3. 从目标 datadir 的 `postmaster.pid` 读取 postmaster PID；
4. 校验该 PID 存活且进程参数包含预期 datadir；
5. 只在该 postmaster 的直属子进程中匹配唯一的 `PG-Strom GPU Service`；
6. 信号仅发送给该唯一子进程，不发送给 postmaster 或 QE backend。

这组校验降低了误杀其他集群、其他 Segment 或普通 backend 的风险。

### 6.3 受控重启语义

脚本向目标 GPU Service 发送 `SIGHUP`。PG-Strom 对该信号的既定处理是：

1. 标记 GPU Service 进入终止状态；
2. 将共享 readiness 清为 false；
3. 关闭 service socket 并清理 GPU context/worker；
4. 以退出码 1 结束 background worker；
5. postmaster 根据 `bgw_restart_time=5` 在五秒后创建新 worker；
6. 新进程重新创建 CUDA context；
7. 无条件按 `pg_strom.max_async_tasks` 重建 task worker pool；
8. worker 数达到目标后才将 readiness 设为 true。

该模型验证的是 PG-Strom 显式支持的 Service restart 路径，不等价于 SIGKILL、CUDA fatal 或 Segment postmaster crash。

### 6.4 无部分结果判定

在旧 Service 已退出、新 Service 尚未启动的窗口内，runner 执行覆盖两个 Segment 的聚合 GpuScan。

查询只有在所有 QE 成功完成后才会产生一个带特殊标记的最终结果行。如果执行返回非零状态，且输出中不存在该标记，则证明 QD 没有把另一个健康 QE 的局部数据作为完整结果返回。

同时 runner 要求错误信息能明确关联 GPU/segment service，例如：

```text
ERROR: failed on connect('.pg_strom.<postmaster-pid>.gpuserv.sock'):
       No such file or directory (seg0 slice1 ...)
```

`pg_strom.cpu_fallback=off` 保证该错误不会被静默 CPU fallback 掩盖。

## 7. 三轮故障恢复实测证据

故障目标为 content 0：

```text
dbid:              2
segment port:      7002
segment postmaster PID: 2249668
configured task workers: 16
```

三轮 GPU Service 代际变化：

```text
cycle 1: 2249740 -> 2283166
cycle 2: 2283166 -> 2283454
cycle 3: 2283454 -> 2283745
```

每轮 Service 不可用期间，查询均得到预期错误：

```text
failed on connect('.pg_strom.2249668.gpuserv.sock'):
No such file or directory (seg0 slice1 ...)
```

每轮均满足：

- psql 返回非零状态；
- 没有输出部分结果标记；
- 错误明确来自 `seg0 slice1` 的 PG-Strom service socket；
- postmaster PID `2249668` 保持不变；
- 新 GPU Service PID 与旧 PID 不同；
- `workers - 16 startup` 日志累计计数依次从 1 增至 4；
- 恢复后的 GPU 签名重新等于 CPU 基线。

最终 runner 输出：

```text
GPU Service failure propagation and recovery passed for 3 cycles on content 0.
```

这证明之前修复的“每个新 GPU Service 进程必须重建私有 worker pool，并在 ready 前检查 worker 数”逻辑在双 Segment 实际环境中有效。

## 8. 资源配置与单机边界

单机双 Primary 拓扑会启动三个独立 GPU Service：

- QD 一个；
- content 0 Primary 一个；
- content 1 Primary 一个。

它们各自拥有 CUDA context、worker pool 和 GPU memory pool。配置采用：

```conf
pg_strom.gpu_mempool_segment_sz = '256MB'
pg_strom.gpu_mempool_max_ratio = 0.20
pg_strom.max_async_tasks = 16
```

`gpu_mempool_max_ratio=0.20` 是当前 GUC 允许的最小硬上限。它是每个 Service 的独立上限，不是主机级统一配额。空闲 Service 不会立即预留完整的 20%，但多个活跃 Service 仍可能竞争同一块 GPU。

因此当前验收严格串行运行，不覆盖多会话并发或资源组隔离。

## 9. 能力边界

| 维度 | 当前状态 | 说明 |
|---|---|---|
| 集群拓扑 | 已验收单机 1 QD + 2 Primary | 动态 runner 要求至少两个正常 Preferred Primary |
| 多主机 | 未验收 | 故障 runner明确拒绝远程目标 |
| Mirror/Standby | 本次未配置 | 未验证 FTS、Mirror 接管和角色切换 |
| 表类型 | 普通分布式 heap | AO/AOCO/分区等继续回退 |
| Planner | PostgreSQL planner，`optimizer=off` | ORCA 仍不产生 GpuScan |
| 条件 | 完整 device qual | host-only 或混合 qual 继续回退 |
| 数据分布 | 均匀、单点倾斜、部分 QE 空扫描 | 已验证全局结果一致性 |
| 类型/值 | bigint、integer、numeric、text、NULL、负数 | 不代表上游全部类型矩阵 |
| 参数/rescan | 基础场景通过 | prepared、参数变化、重复执行、lateral |
| CPU fallback | 验收时关闭 | GPU/Service 错误必须显式传播 |
| Service 故障 | 单 QE 受控 SIGHUP 三轮通过 | 证明退出、错误传播、自动重启和 worker 重建 |
| SIGKILL/CUDA fatal | 未自动验收 | 可能触发更大范围 postmaster recovery |
| Query cancel | 手工范围 | 尚未纳入五条出口的自动 runner |
| 并发隔离 | 未实现 | 多 Service 内存池不是全局配额 |
| 性能 | 不形成结论 | 验收耗时仅用于观察，不是 benchmark |
| 高级算子 | 不支持 | GpuJoin/GpuPreAgg/GpuSort/GpuCache 等仍不注册 |

## 10. Commit 演进

### 10.1 `6e497fd830c` — 多 Segment GpuScan 技术 demo

主要内容：

- 从 `gp_segment_configuration` 动态识别 Primary 数；
- 拒绝单 Primary 和降级拓扑；
- 将固定 `segments: 1` 断言改为实际 Segment 数；
- 新增均匀、倾斜和小表三类数据；
- 增加 NULL、负数和空 QE 覆盖；
- 每类 CPU 签名与三轮 GPU 签名比较；
- 保留 ORCA、AO/AOCO、分区和正则负向测试；
- 使用适合单机多 Service 的 256MB pool segment 和 20% hard limit；
- 扩展静态边界检查。

### 10.2 `f0c1de9e37b` — 端到端构建与双 Primary 启动说明

主要内容：

- 记录从当前 Cloudberry 源码 configure、build、install 的流程；
- 显式固定 Cloudberry heap/WAL block size 为 32KB；
- 记录使用目标安装树 `pg_config` 构建 PG-Strom；
- 使用 `gpdemo` 创建 1 QD + 2 Primary、无 Mirror 的隔离集群；
- 在建集群时统一加入 preload 和 GPU memory pool 配置；
- 增加拓扑、QE GUC、日志和生命周期检查步骤。

### 10.3 `a5d5cb29896` — GPU Service 故障传播与恢复 runner

主要内容：

- 新增显式 opt-in 的 `run_failure_recovery.sh`；
- 精确定位目标 Segment 的 GPU Service；
- 使用 SIGHUP 触发受控 background-worker restart；
- 验证失败查询无部分结果；
- 验证 Service PID 代际变化；
- 验证 worker startup 日志新增；
- 验证恢复后的 CPU/GPU 签名；
- 默认连续执行三轮。

## 11. 验收方法

完整 Cloudberry/PG-Strom 构建和双 Primary 集群初始化步骤见 `cloudberry/demo/README.md`。

先运行多 Segment 正确性 demo：

```sh
PGDATABASE=pgstrom_mvp \
PGSTROM_MVP_REPEAT=3 \
./gpcontrib/pg_strom/cloudberry/demo/run_demo.sh
```

成功后运行故障恢复 demo：

```sh
PGDATABASE=pgstrom_mvp \
PGSTROM_MVP_ALLOW_SERVICE_RESTART=1 \
PGSTROM_MVP_TARGET_CONTENT=0 \
PGSTROM_MVP_RECOVERY_CYCLES=3 \
PGSTROM_MVP_RECOVERY_TIMEOUT=30 \
./gpcontrib/pg_strom/cloudberry/demo/run_failure_recovery.sh
```

源代码环境还应执行：

```sh
bash -n gpcontrib/pg_strom/cloudberry/demo/run_demo.sh
bash -n gpcontrib/pg_strom/cloudberry/demo/run_failure_recovery.sh
gpcontrib/pg_strom/cloudberry/test_static_mvp.sh
make -C src/backend/cdb cdbplan.o
```

## 12. 验收数据如何解读

本次 GPU 查询执行时间大致处于：

- 均匀表签名：约 295～363ms（重复轮次）；
- 倾斜表签名：约 185～226ms；
- 小表签名：约 24～25ms；
- 首次带完整 instrumentation 的计划通常更慢。

这些数据证明查询能够完成，并帮助观察首次执行、缓存和数据倾斜差异，但不能证明 GPU 比 CPU 更快。当前测试使用 `enable_seqscan=off` 以稳定选择 GpuScan，且 QD/QE 共享同一块 GPU，受 CUDA context、fatbin、缓存、Motion 和单机资源竞争影响。

正式性能结论需要独立 benchmark，至少区分：

- CPU Seq Scan 与 GPU Scan；
- 冷/热 OS cache；
- 首次/复用 fatbin；
- 不同数据规模和选择率；
- 均匀/倾斜分布；
- 单查询/并发查询；
- 单 GPU/多 GPU/多主机。

## 13. 下一阶段建议

在继续开放新算子或新存储类型前，建议按以下优先级推进：

1. **多主机 GpuScan**：至少两台 Segment 主机，每台独立 GPU，验证计划、网络 Motion、设备选择和远程故障传播；
2. **并发资源隔离**：解决多个 postmaster GPU Service 各自维护 memory pool 上限、但缺少主机级统一配额的问题；
3. **更强故障模型**：SIGKILL、CUDA fatal、query cancel、Segment postmaster recovery、Mirror 接管和重复恢复；
4. **SQL 可观测性**：暴露 service generation、ready、目标/实际 worker 数、fatbin config signature、任务成功/失败/取消计数；
5. **长稳与泄漏检查**：多小时重复查询、取消和恢复，检查 backend、socket、pthread、CUDA context 和显存；
6. **完整类型/表达式矩阵**：系统化覆盖 device type/function，而不是依赖少量 demo 表达式；
7. **独立性能工程**：建立可复现 benchmark 后再评价成本模型和收益；
8. **逐项能力扩展**：AO/AOCO、分区、host quals、GpuJoin/GpuPreAgg 等分别设计，不直接移除 guard。

## 14. 推荐版本定位

对外描述建议使用：

> Cloudberry PG-Strom v6.1 multi-segment GpuScan technical MVP：在 PostgreSQL planner 下支持普通分布式 heap 表，已完成单机 1 QD + 2 Primary QE 的均匀/倾斜/空 QE 正确性、CPU/GPU 签名、安全回退，以及单 QE GPU Service 受控故障传播和自动恢复验收；不包含多主机、并发资源隔离、Mirror failover、生产级故障模型、ORCA、AO/AOCO、分区表和其他 PG-Strom 加速算子，尚非生产就绪版本。

## 15. 相关文件

- `CLOUDBERRY_GPUSCAN_MVP_DESIGN.md`：单 Primary MVP 的底层设计和演进；
- `CLOUDBERRY.md`：构建方式与支持边界摘要；
- `cloudberry/demo/README.md`：Cloudberry/PG-Strom 构建、双 Primary 集群和验收步骤；
- `cloudberry/demo/postgresql.conf.mvp`：单机共享 GPU 的配置样例；
- `cloudberry/demo/setup.sql`：均匀、倾斜、小表及负向测试数据；
- `cloudberry/demo/verify.sql`：LIMIT、参数、rescan、倾斜和小表执行测试；
- `cloudberry/demo/run_demo.sh`：多 Segment 正确性与边界验收；
- `cloudberry/demo/run_failure_recovery.sh`：单 QE GPU Service 故障传播和恢复验收；
- `cloudberry/test_static_mvp.sh`：实现边界与验收资产静态检查；
- `src/gpu_scan.c`：GpuScan 规划与执行注册；
- `src/gpu_service.c`：GPU Service、worker pool、readiness、fatbin 和任务执行；
- `src/gpu_cache.c`：GpuCache 生命周期防护；
- `../../src/backend/cdb/cdbplan.c`：QD-to-QE CustomScan 重写。
