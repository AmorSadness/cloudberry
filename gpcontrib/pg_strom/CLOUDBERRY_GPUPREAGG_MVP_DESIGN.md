# Cloudberry GpuPreAgg Gather-only MVP 设计

> 前置基线：`CLOUDBERRY_GPUSCAN_HOST_QUALS_MILESTONE.md`  
> 上游基线：PG-Strom v6.1，commit
> `4d12ef415759dc48cd4c1421565e9c694b7bd3f9`  
> 设计日期：2026-08-10  
> 当前状态：Gather-only MVP 源码已实现，真实双 Primary GPU M1/M2 与 M3
> cancel、SIGHUP、SIGKILL 验收及故障后的最终全量回归均已通过；M4a 结构化
> 成本与内存估算已于 2026-08-13 完成真实单机双 Primary、共享单 GPU 计划与
> 正确性验收

## 1. 结论

Cloudberry PG-Strom 在 GpuScan 之后优先移植 GpuPreAgg。本阶段采用
**Gather-only MVP**：每个 QE 使用 GpuPreAgg 对本 Segment 数据生成局部聚合
状态，随后通过 Cloudberry Motion 汇集这些状态，并由 CPU final aggregate
完成跨 Segment 合并。

目标计划的逻辑形状为：

```text
CPU Final Aggregate
  -> Gather Motion N:1
       -> Custom Scan (GpuPreAgg)
            GPU Scan Quals: ...
            GPU Pre-Aggregation: ...
```

GpuPreAgg 不是独立读取另一个输入计划的普通 Agg 节点，而是复用 PG-Strom 的
scan/pre-aggregation 融合管线：GpuScan 读取和过滤本地 heap tuple，GPU 在返回
QE 前生成 partial states。Motion 传输的是 partial rows，不是原始明细行。

Gather-only 是有意选择的正确性优先方案。即使 GROUP BY key 与表分布键无关，
同一个 group 出现在多个 Segment，也会在 Motion 后被统一合并。本阶段不尝试
直接输出每个 QE 的 GPU final buffer，也不生成按 GROUP BY key 的 Redistribute
Motion。

## 2. 为什么 GpuPreAgg 是下一个算子

GpuPreAgg 可以最大程度复用已经完成真实双 Primary 验收的基础设施：

- 普通分布式非分区 heap 的 GpuScan；
- 每个 QD/QE postmaster 独立的 GPU Service；
- device expression codegen 和 tuple/KDS ABI；
- QD-to-QE CustomScan plan mutation；
- executor、query cancel、SQL Service status；
- SIGHUP 和 SIGKILL/Segment crash recovery runner。

与 GpuJoin 相比，GpuPreAgg 只涉及一个分布式关系，不需要在首个里程碑同时解决
两侧 locus、broadcast/redistribute、inner preload、outer join NULL 扩展和
多级 join rows/cost。与 GpuSort 相比，PG-Strom v6.1 的 GpuSort 是附着在
GpuScan/GpuJoin/GpuPreAgg final buffer 上的增强能力，不是适合作为下一阶段的
独立关系算子。

GpuPreAgg 还能在低到中等 group cardinality 下减少进入 Motion 的数据量，符合
MPP 聚合的主要收益方向。首个里程碑只证明计划和结果正确，不形成性能结论。

## 3. 当前源码基础与不能直接开放的原因

上游源码已经包含：

- aggregate function catalog 与 partial/final function 映射；
- grouping key、aggregate target 和 HAVING target 的构造；
- GpuPreAgg CustomPath、CustomScan 和 executor methods；
- `cuda_gpupreagg.cu` device implementation；
- GPU Service final-buffer merge；
- GpuSort、window rank 和 Top-N 附加逻辑。

Cloudberry 当前在 `_PG_init()` 中通过 `#ifndef GP_VERSION_NUM` 不调用
`pgstrom_init_gpu_preagg()`。不能只删除这一条件，原因如下。

### 3.1 CustomPath 缺少 Cloudberry 字段

GpuPreAgg 上游 CustomPath 没有设置 Cloudberry 扩展的：

- `memory`；
- `locus`；
- `motionHazard`；
- `barrierHazard`；
- `rescannable`；
- `sameslice_relids`。

这些字段必须像现有 GpuScan 一样显式且保守地初始化。未初始化或错误 locus
可能导致非法 Motion 放置、错误的 group 完整性判断或 add_path 阶段失败。

### 3.2 PostgreSQL Gather 不等于 Cloudberry Motion

上游 GpuPreAgg 在 CPU fallback、无 GROUP BY 或 PostgreSQL parallel path 下，
可以构造 `Agg + Gather + GpuPreAgg`。这里的 Gather 合并同一个 PostgreSQL
实例中的 parallel workers，不能表示 Cloudberry Segment 之间的数据交换。

Cloudberry 必须使用 `cdbpath_create_motion_path()` 等 MPP path API 构造 Motion，
并携带合法的目标 locus。

### 3.3 每 QE GPU final 不是全局 final

上游在 `cpu_fallback=off` 且存在 GROUP BY 时，可以跳过 CPU Agg 并把 GPU
final buffer 直接作为结果。多 Segment 下，除非已证明 GROUP BY keys 与输入
distribution keys 完全共置，否则不同 QE 可能输出相同 group 的不同 partial
row。直接返回会产生重复 group 和错误聚合值。

因此 Cloudberry Gather-only MVP 无条件保留跨 Segment CPU final aggregate，
不使用该 GPU-only final shortcut。

### 3.4 一个初始化函数同时开放多个能力

`pgstrom_init_gpu_preagg()` 同时注册 GpuPreAgg、numeric aggregate、partitionwise
GpuPreAgg 和 GpuSort GUC。Cloudberry 必须分别设置默认值和 planner guard，不能
因为注册 GpuPreAgg 而顺带开放尚未设计的 GpuSort、partitionwise 或 numeric
能力。

## 4. MVP 能力边界

### 4.1 支持范围

- PostgreSQL planner，`optimizer=off`；
- 普通分布式、非分区 heap；
- 每个 QE 只处理其本地 Segment 数据；
- 至少一个可在 GPU 执行的 scan qual；
- scan quals 必须全部可以下推到 device；
- `GROUP BY` 或无 GROUP BY 的普通聚合；
- 第一阶段 aggregate whitelist：
  - `count(*)`、`count(expr)`；
  - `sum`；
  - `min`；
  - `max`；
  - 首轮仅开放经过逐类型验证的整数和浮点类型；
- Motion 后由 CPU 执行 final aggregate；
- CPU fallback 在验收环境保持 `off`，GPU 错误显式失败。

### 4.2 默认关闭

Cloudberry GpuPreAgg 定位为实验能力，默认关闭。建议保留上游 GUC 名称：

```text
pg_strom.enable_gpupreagg = off
```

在 `GP_VERSION_NUM` 构建中将默认值设为 `off`；会话显式设置为 `on` 后，只有
满足全部 Cloudberry eligibility guards 的查询才能生成 GpuPreAgg。

以下相关能力也必须默认关闭：

```text
pg_strom.enable_partitionwise_gpupreagg = off
pg_strom.enable_numeric_aggfuncs = off
pg_strom.enable_gpusort = off
```

### 4.3 明确不支持

- ORCA；
- AO、AOCO、foreign/Arrow、replicated、coordinator-local 表；
- 分区父表和 `RELOPT_OTHER_MEMBER_REL` 叶子；
- mixed host/device scan quals；
- host-only scan quals；
- partitionwise GpuPreAgg；
- aggregate `DISTINCT`；
- aggregate `FILTER`；
- `GROUPING SETS`、`ROLLUP`、`CUBE`；
- ordered-set 和 hypothetical-set aggregates；
- aggregate 内部 `ORDER BY`；
- 尚未进入 whitelist 的 aggregate/type；
- numeric aggregate；
- GpuSort、Top-N 和 window rank；
- GPU-only final aggregate；
- Redistribute Motion + parallel final aggregate；
- GpuJoin、GpuCache、GPU-Direct、SELECT-INTO-Direct 和 DPU；
- 多主机、Mirror/FTS、资源组/用户级公平调度和性能承诺。

`HAVING` 在首个代码里程碑也保持关闭。等 Gather-only partial/final 结果稳定后，
再单独验证 HAVING 表达式替换、NULL 三值逻辑和 Motion 后执行位置。

## 5. 正确性模型

设分布式表在 `S` 个 Primary Segment 上，每个 Segment `s` 的输入集合为
`R_s`。GpuPreAgg 在每个 QE 上计算：

```text
P_s = PartialAggregate(Filter(R_s))
```

Gather Motion 形成：

```text
P = P_0 UNION ALL P_1 ... UNION ALL P_(S-1)
```

CPU final aggregate 计算：

```text
FinalAggregate(P)
```

partial/final function 必须满足可合并性，使该结果等价于：

```text
Aggregate(Filter(R_0 UNION ALL ... UNION ALL R_(S-1)))
```

这一定义覆盖：

- 同一个 group 只存在于一个 Segment；
- 同一个 group 横跨多个 Segment；
- 数据完全倾斜在一个 Segment；
- 一个或多个 QE 空输入；
- 整个分布式输入为空。

### 5.1 空输入

无 GROUP BY 的聚合必须由 Motion 后 CPU final aggregate 保证 SQL 空输入语义：

- `count(*)`、`count(expr)` 返回 `0`；
- `sum`、`min`、`max` 返回 `NULL`。

不能依赖每个 QE 都输出一行再直接返回，否则会得到每 Segment 一行，或者在空
QE 数量变化时得到不同结果。

### 5.2 NULL 和溢出

partial state 必须保留 aggregate 的 NULL 语义。整数 `sum` 的 transition/result
类型和溢出行为必须与 CPU baseline 一致，不能只比较非边界数据。浮点聚合验收
应使用确定的比较规则；若 CPU/GPU 浮点归并次序导致 bitwise 差异，应先明确
容差策略，不能把不稳定文本格式当作正确性签名。

## 6. Planner 与 Path 设计

### 6.1 Eligibility guards

GpuPreAgg upper-path hook 在创建任何 path 前检查：

1. Cloudberry 实验 GUC 已开启；
2. `optimizer=off` 对应的 PostgreSQL planner 正在工作；
3. GPU Service ready；
4. 输入来源是已通过 Cloudberry GpuScan guards 的普通分布式非分区 heap；
5. GpuScan path tracker 中存在 non-parallel、无 host qual 的合法 GPU outer path；
6. 至少存在一个 device scan qual；
7. aggregate、argument 和 group key 均在本阶段 whitelist；
8. 不存在 DISTINCT、FILTER、grouping sets、aggregate ORDER BY 或 HAVING；
9. 不生成 partitionwise、GpuSort 或 DPU 变体。

首个 MVP 不扩大现有 mixed-quals GpuScan 的融合范围。虽然 mixed quals 可以由 QE
执行 `ExecQual()`，但在聚合融合管线中，host filter 必须发生在 partial aggregate
之前；现有 path tracker 有意不记忆带 host quals 的可融合 outer path，因此保持
安全回退。

### 6.2 GpuPreAgg CustomPath locus

GpuPreAgg 在各 QE 原地执行，不包含输入 Motion。它继承输入 GpuScan 的 Segment
集合，但 partial target 可能不再包含原 distribution keys。

Gather-only MVP 对 GpuPreAgg 输出采用保守 locus：

- 保留实际执行的 `numsegments` 和 parallel worker 信息；
- 若无法严格证明 projection 后 distribution key 仍有效，则标记为 `Strewn`；
- 不利用该 locus 宣称 group 已经全局完整；
- 后续无条件添加目标为 bottleneck locus 的 Motion。

这避免 planner 因错误的 Hashed locus 跳过跨 Segment final aggregate。未来
Redistribute 里程碑可以使用 `cdbpathlocus_pull_above_projection()` 和
`choose_grouping_locus()` 做更精确推导，但不属于本阶段出口。

### 6.3 其他 Cloudberry Path 字段

GpuPreAgg CustomPath 至少按以下原则初始化：

- `memory`：记录或保守估算每 QE executor/GPU final-buffer 所需内存；若首版没有
  可用估算，先设为零并在设计限制中明确，不读取未初始化值；
- `motionHazard=false`：GpuPreAgg 自身及其融合的本地 GpuScan 不包含 Motion；
- `barrierHazard=false`：首版不使用 Parallel Hash barrier；
- `rescannable=true`：沿用已验收的 GpuScan reset/reconnect 语义，并通过实际
  rescan 用例验证；若测试不能证明，则改为 false 并依赖 Materialize；
- `sameslice_relids`：使用输入普通 heap baserel 的 relids；
- `parallel_workers`：必须与 locus 中的 worker 数一致。

本阶段优先使用 non-parallel GpuPreAgg path，避免同时引入 QE 内 PostgreSQL
parallel worker 与 Segment 两层并行。QE 内 parallel path 属于后续扩展。

### 6.4 Motion 和 final aggregate

GpuPreAgg path 创建完成后，Cloudberry 分支不进入上游 `create_gather_path()`
逻辑，而是构造：

1. GpuPreAgg partial path；
2. Gather Motion 到单一执行位置；
3. CPU final aggregate；
4. 必要时由 Cloudberry 后续 planner 将最终结果送到 QD。

具体目标可以是 Cloudberry 选择的 SingleQE/bottleneck locus；最终计划必须保证
只有一个 final aggregate 实例看到所有 partial rows。不能在每个 QE 上分别执行
final aggregate 后直接 Gather 结果。

首版只生成一个 Gather-only 候选，不同时生成 Redistribute 候选。这样计划形状、
故障传播和结果签名具有确定性。

## 7. Target list 与 plan mutation

GpuPreAgg 继续复用上游 target 构造：

- device partial target 保存聚合 transition/partial state 和 group keys；
- Motion 传输 partial target；
- CPU final target 使用 PG-Strom aggregate catalog 中对应的 final aggregate
  functions；
- 最终 projection 恢复用户查询要求的类型和列顺序。

Cloudberry `src/backend/cdb/cdbplan.c` 已递归 mutation：

- `CustomScan.custom_plans`；
- `CustomScan.custom_exprs`；
- `CustomScan.custom_scan_tlist`；
- 标准 Plan 字段，包括 `plan.qual` 和 target list。

`custom_private` 继续是扩展 opaque data，核心不解释或 mutation。所有 QE 执行所
依赖的 Var/Param 表达式必须同时出现在会被核心重写的标准字段或
`custom_exprs/custom_scan_tlist` 中，不能只藏在 `custom_private`。

首轮计划测试必须检查 QD plan、dispatch 后 QE plan和 `EXPLAIN (VERBOSE)`，防止
partial/final target 在 Motion 或 setrefs 阶段发生 Var 编号错误。

## 8. 成本模型

Cloudberry `RelOptInfo` 的基础统计是全局值，Path rows 和运行成本是每 QE 值。
现有 GpuScan 已把 scan tuples/pages/running work 按 Segment 数缩放，GpuPreAgg
必须沿用这一口径，不能再次除以 Segment 数。

### 8.1 GpuPreAgg 每 QE 成本

- 输入 rows：继承已缩放的 GpuScan `pp_info`；
- device qual 成本：继承 GpuScan；
- partial aggregate 运算：按每 QE 输入 rows 和 group key/aggregate 数计算；
- partial output rows：估算每 QE local group 数；
- GPU-to-host DMA：按每 QE partial rows 和 partial tuple width 计算；
- startup cost：每个 QE 独立承担，不除以 Segment 数；
- final-buffer 内存：按每 QE local groups 和 partial width 估算。

M4a 的实现口径如下：

- 先使用全局 `RelOptInfo.rows` 估算 global groups，再通过输入 locus、Segment 数
  和已经按 QE 缩放的输入 rows 调用 `estimate_num_groups_on_segment()`，得到每 QE
  local groups；若 GROUP BY keys 覆盖 hashed distribution keys，则按 Segment 数
  分摊 global groups 并受每 QE input rows 上限约束；不再对全局 NDV 简单重复
  执行一次 `estimate_num_groups()`；
- GPU grouping/aggregate startup work 以每 QE input rows 计费，partial-state
  materialization 和 DMA 以 local groups 计费；DMA 另按 partial tuple width 的
  64-byte 单位作保守缩放。该宽度因子用于避免宽 partial state 与窄 state 同价，
  仍需真实 benchmark 校准；
- planner 与 executor 共用 `estimateGpuPreAggFinalBufferSize()`。GROUP BY hash
  buffer 按 KDS header、hash slots、row-index/lock 区和 tuple area 估算，并保持
  executor 既有的每设备最小 1GiB 分配；无 GROUP BY 保持每设备 4MiB；
- `Path.memory` 记录所有可见 GPU 的每 QE final-buffer 总估算值。若单设备估算
  无法由 KDS 32-bit slot 字段表示、发生 `size_t` 溢出，或超过最小可见设备的
  物理显存，则不生成 GpuPreAgg path，安全回退原生聚合；
- `EXPLAIN` 的 `GpuPreAgg Sizing` 显示 local groups 和每设备 buffer 估算；
  `EXPLAIN ANALYZE` 还显示实际 final nitems、usage 和 total，供 GPU 回归校准。

### 8.2 Motion 与 CPU final 成本

- Motion 输入 rows：各 QE partial rows 的全局合计；
- Motion width：partial state target width，而不是用户最终 target width；
- CPU final 输入：全部 partial rows；
- CPU final 输出：全局 group 数，无 GROUP BY 时为一行；
- final projection 和 HAVING：首版只有 projection，没有 HAVING；
- Gather-only 的 bottleneck 成本必须保留，不能为了强制暴露 GpuPreAgg 而伪造
  低成本。

M4a 不在扩展内重复计算上述两层成本：`cdbpath_create_motion_path()` 根据
GpuPreAgg 每 QE partial rows、Segment 数和 partial target 建立 Gather Motion
成本，随后 `create_agg_path()` 根据 Motion 的全局输出 rows 和 global groups
计算 CPU final aggregate。这样避免扩展收费一次、Cloudberry 标准 Path 再收费
一次。

正确性验收可临时通过 planner GUC 或成本参数暴露合法 path，但文档和 runner
必须明确这不证明 planner 会在默认成本下选择 GpuPreAgg，也不证明性能收益。

## 9. 初始化与代码改动边界

预计代码工作集中在：

### 9.1 `src/main.c`

- Cloudberry GPU 分支只新增 `pgstrom_init_gpu_preagg()`；
- 继续不调用 `pgstrom_init_gpu_join()`、`pgstrom_init_gpu_cache()` 和
  `pgstrom_init_select_into()`；
- DPU 初始化保持关闭。

### 9.2 `src/gpu_preagg.c`

- 为 Cloudberry 设置 GUC 默认值；
- 增加 Cloudberry eligibility guards；
- 初始化 CustomPath 的 MPP 字段；
- 禁止 partitionwise、numeric、GpuSort 和 GPU-only final shortcut；
- 使用 Cloudberry Motion path 取代 PostgreSQL Gather；
- 修正每 QE local groups、Motion rows 和全局 final groups 成本；
- 保持上游非 Cloudberry 行为不变。

### 9.3 Cloudberry core

优先不修改 Cloudberry core。先使用已有公开 planner/path API 和已经完成的
CustomScan mutation。如果实现中发现 extension hook 时点无法合法构造 Motion
与 final aggregate，必须先记录具体 API/target 缺口，再评估增加最小 core hook；
不能通过伪造 locus 或在 plan 创建后手工插入 Motion 绕过 path planner。

### 9.4 SQL 与 demo

- 扩展 SQL 只在确有新增 SQL 对象时升级版本；单纯注册已有 GUC/CustomScan 不
  为版本升级的充分理由；
- 新增独立 GpuPreAgg setup/verify/runner，避免破坏已验收 GpuScan runner；
- 扩展静态脚本，检查默认关闭、初始化边界和负向 guards。

## 10. 分阶段实现

### M0：注册与静态边界

- Cloudberry 构建注册 GpuPreAgg methods 和 GUC；
- 默认关闭；
- GpuSort、numeric、partitionwise 仍关闭；
- host 编译、静态 guards、`git diff --check` 通过；
- 未开启 GUC 时原 GpuScan 计划和测试不变。

### M1：单 Primary partial/final ABI

- 真实 GPU 单 Primary 生成 GpuPreAgg；
- count/sum/min/max 与 CPU baseline 一致；
- 空输入、NULL、负数和边界值正确；
- prepared statement、重复执行和基础 rescan 通过；
- EXPLAIN 能区分 GPU scan quals、pre-aggregation 和 CPU final aggregate。

单 Primary 不能证明 MPP partial merge，只用于隔离 device ABI 和 target-list
问题。

### M2：双 Primary Gather-only 正确性

- 计划包含合法 Gather Motion；
- 同一个 group 横跨两个 Segment 时只输出一个最终 group；
- uniform、skew、small/empty QE 签名与 CPU baseline 一致；
- 无 GROUP BY 聚合只输出一行；
- Motion rows 与 partial rows 的 EXPLAIN 统计合理；
- QD/QE Service command counters 能观察到两个 QE 的命令。

### M3：取消与故障恢复

- query cancel 后 client/queue/active commands 排空；
- 单 QE Service SIGHUP 时整条分布式聚合明确失败，不返回部分 aggregate；
- SIGKILL/Segment crash recovery 后 Service 和结果签名恢复；
- 故障前后 partial/final 结果没有重复或遗漏。

真实双 Primary GPU 验收于 2026-08-10 完成：

- query cancel 连续三轮通过；每轮精确取消目标 QD backend，所有新增 GPU
  submission 均进入 completed/failed/cancelled 终态，client/queue/active 排空，
  恢复后的 GpuPreAgg signature 与 CPU baseline 一致；
- content 0 GPU Service SIGHUP 连续三轮通过；Service PID 每轮替换，generation
  从 1 依次增长到 4，故障窗口内分布式聚合明确失败且没有部分结果，worker
  pool 和 signature 均恢复；
- content 0 GPU Service SIGKILL 连续三轮通过；每轮 Service PID 和 worker 启动
  日志均更新，Segment crash recovery 重建 shared-memory epoch 后 generation 允许
  重置，恢复后的 GpuPreAgg signature 与 CPU baseline 一致；
- 故障验收完成后，既有多 Segment GpuScan 全量 runner 与 Gather-only GpuPreAgg
  M1/M2 runner 均再次通过。

### M4a：结构化成本与内存估算

- 全局 groups 与每 QE local groups 使用 Cloudberry locus 语义分层估算；
- partial 运算、宽度相关 DMA、Motion 和 CPU final 的成本责任清晰且不重复；
- planner/executor 使用相同 final-buffer 公式，`Path.memory` 不再为零；
- 无法表示或超过单设备物理显存的估算安全回退；
- `EXPLAIN (ANALYZE)` 暴露估算和实际 final-buffer 指标；
- 源码、静态检查与真实 GPU 验收均已完成。

真实 GPU 验收于 2026-08-13 在单机 1 QD + 2 Primary、三个 postmaster 共享
同一块 GPU 的环境完成：

- uniform cross-Segment groups、global aggregate、float8 aggregate、单 Segment
  skew、仅一个 QE 非空和全空输入六类正向计划均生成 Gather-only GpuPreAgg；
- 每个正向计划均显示双 Primary Gather Motion 和 `GpuPreAgg Sizing`；GROUP BY
  计划显示每设备 1024MiB 的既有最小 hash buffer，无 GROUP BY 计划显示每设备
  4096KiB buffer；
- 六类查询各连续执行三轮，CPU/GPU 结果全部一致；
- no device qual、mixed quals、numeric、FILTER、HAVING、AO/AOCO、分区表和
  ORCA 等负向边界继续使用原生计划；
- runner 最终输出 `Cloudberry Gather-only GpuPreAgg MVP acceptance passed`。

本次 M4a 验收确认结构化行数/成本口径、planner/executor sizing 公式、计划
放置和结果正确性在上述拓扑下成立。local-group 估算仍是保守估算，成本常量与
估算精度校准、高基数压力和性能结论继续属于 M4b；M4a 结果本身不外推到多主机、
独立 GPU 或并发隔离，后续 P0 已另行完成单机共享 GPU 资源门验收。

### M4b：成本校准和性能探索

M4b 在单机共享 GPU 拓扑下由 P0 资源门前置。主机级预算、并发 admission 与
异常回收的实现见 `CLOUDBERRY_SHARED_GPU_BUDGET_DESIGN.md`。P0 已于 2026-08-13
完成 24 客户端并发 admission、三轮 cancel、三轮 GPU Service SIGKILL/stale
reclaim 及故障后 M1–M4a 全量回归；单机同用户/同 PID namespace 的资源门已通过，
但不代表多主机协调或资源组公平性。

扩展 6.3 进一步补齐静态 Service 配额和/安全余量诊断、planner-derived request
追踪、GpuScan+GpuScan、GpuScan+GpuPreAgg 以及受控 allocation-failure rollback
runner。真实 GPU 矩阵已于 2026-08-13 通过：两种组合结果匹配且资源排空，历史
1GiB request 可观察，注入失败无泄漏/无部分结果且后续查询恢复。因此 P0a/P0b/P0c
在当前单机共享 GPU 边界内均完成验收。

M4b 已完成代码和静态验收，真实 GPU 验收待执行。实现包括 16MiB grouped buffer
下限、2MiB 对齐、自适应几何扩容、五段成本分解、estimate/actual 偏差指标以及
不写入强制成本参数的 normal-planner runner。低/中/高基数、均匀/倾斜、明细与
partial Motion、适合/不适合 GpuPreAgg 的选择边界均纳入矩阵。完整设计和完成定义
见 `CLOUDBERRY_GPUPREAGG_M4B_DESIGN.md`；在 GPU 日志通过前不宣称 M4b 验收完成。

### 后续非本 MVP 阶段

- Redistribute Motion by GROUP BY keys + parallel final aggregate；
- 已证明 group keys 覆盖 distribution keys 时的无 Motion/local final 优化；
- HAVING；
- numeric 和更多 aggregates/types；
- mixed host/device quals 在 pre-aggregation 之前执行；
- GpuSort/Top-N/window rank；
- GpuHashJoin。

## 11. 验收矩阵

### 11.1 计划与开关

- `pg_strom.enable_gpupreagg` 默认 `off`；
- GUC off：聚合不含 GpuPreAgg；
- GUC on 且合法查询：包含 GpuPreAgg、Gather Motion、CPU final aggregate；
- 不包含 GpuSort、GpuJoin 或 GPU-only final；
- ORCA、AO/AOCO、分区、replicated/local 表安全回退；
- mixed/host-only quals 安全回退；
- unsupported aggregate/type 安全回退而不是 ERROR。

### 11.2 数据形状

- uniform：各 Segment 均有数据且 group 跨 Segment；
- skew：全部或绝大多数数据在一个 Segment；
- small：只有一个 QE 非空；
- empty：所有 QE 为空；
- high cardinality：local groups 接近输入 rows；
- NULL-heavy：group key、aggregate argument 包含 NULL；
- boundary：整数负数、零、最大/最小附近值。

### 11.3 查询形状

```sql
SELECT count(*) ... WHERE <device qual>;

SELECT grp, count(*), sum(v), min(v), max(v)
FROM fact
WHERE <device qual>
GROUP BY grp;
```

还应覆盖：

- 多个 aggregate 共用同一次扫描；
- prepared device qual 参数；
- LIMIT 位于聚合结果之上，但不启用 GpuSort；
- 重复执行；
- 可合法形成 rescan 的 lateral/subquery 形状；
- CPU/GPU 有序规范化后的结果签名比较。

### 11.4 故障与资源

- query cancel；
- SIGHUP Service restart；
- 显式双重授权的 SIGKILL；
- GPU Service queue/active/client 归零；
- final-buffer 内存高水位诊断；
- 恢复后 CPU/GPU 签名一致。

## 12. 里程碑出口

只有以下条件全部满足，才能把 Gather-only GpuPreAgg 描述为已完成：

1. 默认关闭和全部负向 guards 已通过静态与真实集群验证；
2. 单 Primary partial/final ABI 正确；
3. 至少双 Primary 的 Gather Motion 计划和执行正确；
4. 跨 Segment 同组、skew、empty QE 和全空输入结果正确；
5. count/sum/min/max whitelist 的 NULL 和边界语义与 CPU 一致；
6. prepared、重复执行、LIMIT 和 rescan 基础形状通过；
7. query cancel、SIGHUP、SIGKILL/crash recovery 不返回部分结果且可恢复；
8. 原 GpuScan device-only、mixed quals、observability/recovery 验收不退化；
9. 文档明确 Gather-only、默认关闭、无性能结论和其他保留边界。

完成后的对外描述建议为：

> Cloudberry PG-Strom experimental Gather-only GpuPreAgg milestone：在
> PostgreSQL planner 下，对普通分布式非分区 heap 由各 QE GPU 执行本地扫描、
> device filtering 和 partial aggregation，经 Gather Motion 后由 CPU final
> aggregate 合并；能力默认关闭并完成多 Segment 正确性与故障恢复验收。不包含
> ORCA、AO/AOCO、分区、mixed quals、HAVING、DISTINCT aggregate、numeric、
> GpuSort、Redistribute final aggregation、多主机或性能承诺。

上述出口已于 2026-08-10 完成真实双 Primary GPU 验收及故障后全量
回归。当前应使用上述对外描述，并继续保留“实验特性、默认关闭、
无性能结论”以及其他明确的能力边界。
