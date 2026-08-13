# Cloudberry GpuPreAgg M4b 成本、内存与性能校准设计

状态（2026-08-13）：实现、静态检查和单机 1 QD + 2 Primary 共享 Tesla T4 的
真实 GPU 验收全部通过。M4b P0 在本文限定拓扑内完成；不外推为多主机、独立 GPU、
资源组公平性或所有 SQL 形状的性能结论。

## 1. 完成定义

M4b 不以“通过人为成本参数生成 GpuPreAgg”作为完成。完成必须同时满足：

1. 验收会话保持 `gp_enable_multiphase_agg=on`、`enable_seqscan=on`，CPU/GPU
   成本均为正常非零值；Motion GUC 使用正常值（Cloudberry 的 `0`
   表示采用 `2 * cpu_tuple_cost`，不是零成本）；
2. 低、中和仍有明显压缩收益的高基数组由普通 Postgres planner 稳定选择
   GpuPreAgg；按分布键、接近一行一组的反例使用原生聚合；
3. 低基数 grouped final buffer 明显小于 1 GiB；
4. `EXPLAIN ANALYZE` 同时给出 groups 和 bytes 的 actual/estimate 偏差；
5. 明细行 Motion 与 partial-row Motion 有可复查的实际 rows 对比；
6. 共享 GPU 并发矩阵继续通过，allocation failure 后预算与查询状态排空。

## 2. 成本模型

GpuPreAgg 节点在 `EXPLAIN` 的 `GpuPreAgg Cost` 中拆分五项：

- **GPU setup**：沿用 `pg_strom.gpu_setup_cost`；底层 GpuScan 已持有该启动
  成本，分解值用于解释，不重复累加；
- **host-device DMA**：输入按 1 KiB 传输量子计费，最小为每 tuple 的 1/16
  量子；GPU partial state 返回按 64-byte cache line 计费；系数沿用
  `pg_strom.gpu_tuple_cost`；
- **partial aggregate**：group key 和 aggregate expression 对输入行的设备运算，
  系数沿用 `pg_strom.gpu_operator_cost` 及现有 GPU operator ratio；
- **QE→QD Motion**：由 `cdbpath_create_motion_path()` 计费；GpuPreAgg 行标记为
  `native Path`，实际数值保留在上层 Motion 的标准 plan cost 中；
- **CPU final aggregate**：由 `create_agg_path()` 计费；GpuPreAgg 行标记为
  `native Path`，实际数值保留在上层 Aggregate 的标准 plan cost 中。

这样能明确五段成本的所有权，并通过 `EXPLAIN (COSTS ON)` 的节点累积 cost 计算
Motion/Agg 增量，而不把最终路径选择后才确定的上层值错误复制进共享的
GpuPreAgg PlanInfo。GpuScan 原本针对明细行的 device→host `final_cost` 在融合路径中
不继承；它被输入 DMA、partial state 返回、Motion 和 CPU final 的结构化成本替代。

当每 QE 估算 partial rows 已达到输入行的 50% 时，路径在规划阶段判为不适合：
这种形状不能显著减少 Motion，却仍承担 pinned hash buffer、GPU setup 和 QD final
成本。该 reduction gate 保证按分布键、接近一行一组的查询回到原生聚合；低、中、
高但仍有足够压缩比的形状继续由完整成本竞争决定。

## 3. 自适应 final buffer

grouped buffer 仍包含 KDS header、hash slots、row-index/lock 区和两倍估算 tuple
空间。M4b 的变化为：

- grouped buffer 最小值从 1 GiB 降为 16 MiB；
- 大于最小值的估算向 2 MiB 对齐；
- no-group aggregate 保持 4 MiB；
- 运行时空间不足时按 `old + max(old, 16 MiB)` 几何扩容，不再以 1 GiB 为最小
  扩容步长；
- 扩容仍在旧 buffer 存活期间为完整 replacement 预留共享预算，因此 P0
  admission 继续覆盖真实峰值，而不是只预留 delta。

planner、executor session KDS 和 `EXPLAIN` 继续调用同一个
`estimateGpuPreAggFinalBufferSize()`。不可表示、hash slot 超过 32-bit 或超过设备
物理显存时仍不生成 GpuPreAgg Path。

`GpuPreAgg Sizing` 保留 planner estimate。Cloudberry 的 QD 侧
`ExplainCustomScan` 没有 QE 私有计数，因此 M4b 同时通过 `INSTRUMENT_CDB` extra
text 把每个获胜 QE 的 `GpuPreAgg Actual` 传回 QD；其中包含
`groups actual/estimate`、`usage/estimate`、actual items、payload usage 和 total
KDS bytes。高基数偏差因此可以区分 NDV 估算偏差与 tuple/KDS 空间保守度。

## 4. 验收矩阵

`cloudberry/demo/run_gpupreagg_m4b.sh` 不设置关闭 multiphase aggregate、GPU 成本
清零、极大 Motion/CPU 成本或关闭 seqscan 等验收专用参数。runner 会反向检查
multiphase 和 seqscan 为 on，CPU/GPU 成本为正常正数；Motion 允许正常的 `0`
sentinel，但拒绝验收专用极大值。

数据形状：

- uniform low：`grp`，约 1,000 groups；
- uniform medium：`grp_medium`，约 16,384 groups；
- uniform high：`grp_high`，约 131,072 groups；
- uniform near-detail：按 `id` 聚合；
- single-Segment skew low：按 `metric` 聚合；
- single-Segment skew medium/high：按有统计信息的 `grp_medium`/`grp_high` 聚合；
- single-Segment skew near-detail：按 `id` 聚合。

中/高基数键是 setup 中的实体列并执行 `ANALYZE`，避免把“表达式没有 NDV 统计”
误判为 hash sizing 模型偏差。升级已有 demo 数据库后必须重跑 `setup.sql`。

同一 SQL 连续规划三次，计划文本必须一致。uniform low/medium/high 必须自动选择
GpuPreAgg；near-detail 反例必须选择原生聚合。skew low 允许普通 planner 根据单个
非空 Segment 的实际收益选择 GPU 或原生，但选择必须稳定；若选择 GPU，同样检查
成本和 sizing 指标。runner 还用明细查询的 Gather Motion actual rows 对比 low
GpuPreAgg 的 partial Motion actual rows。

共享 GPU 回归由 `run_shared_gpu_concurrency_matrix.sh` 执行。该 runner 的
GpuScan/GpuPreAgg 会话也不再写入上述强制成本参数，并检查最新 planner-derived
请求在 `[16 MiB, 1 GiB)` 内，而不是历史固定 1 GiB。

## 5. GPU 执行步骤

重新编译安装 PG-Strom 并重启集群后执行：

```bash
PGDATABASE=pgstrom_mvp \
PGSTROM_GPUPREAGG_M4B_REPEAT=3 \
./gpcontrib/pg_strom/cloudberry/demo/run_gpupreagg_m4b.sh \
  | tee /tmp/pgstrom-m4b.log

PGDATABASE=pgstrom_mvp \
PGSTROM_SHARED_BUDGET_CLIENTS=24 \
PGSTROM_SHARED_BUDGET_REQUIRE_REJECTION=0 \
./gpcontrib/pg_strom/cloudberry/demo/run_shared_gpu_budget.sh \
  | tee /tmp/pgstrom-m4b-budget.log

PGDATABASE=pgstrom_mvp \
./gpcontrib/pg_strom/cloudberry/demo/run_shared_gpu_concurrency_matrix.sh \
  | tee /tmp/pgstrom-m4b-concurrency.log
```

成功标志分别为：

- `Cloudberry GpuPreAgg M4b normal-cost acceptance passed`；
- `shared GPU budget concurrent acceptance passed`（自适应低基数 buffer 下不再要求
  人为制造 rejection；成功容量应明显高于历史固定 1GiB）；
- `Cloudberry shared-GPU P0a/P0c concurrency matrix passed`。

## 6. 真实 GPU 验收记录

2026-08-13 在单机 1 QD + 2 Primary 共享 Tesla T4 环境完成：

- planner 使用 `on|100|0.01|0.00015625|0|0.01|0.0025|on`，即 multiphase 与
  seqscan 开启、GPU/CPU 成本为正常非零值、Motion 使用正常 `0` sentinel；
- uniform low/medium/high 连续三次稳定自动选择 GpuPreAgg；near-detail uniform
  和 skew 自动选择原生聚合；skew low/medium/high 在普通成本下选择 GpuPreAgg；
- uniform/skew 的低、中、高基数六类结果 digest 均匹配 CPU；
- low uniform 每设备 buffer 为 16MiB，实际 1,000 groups、125KiB payload，
  groups actual/estimate 为 1.00x；
- high uniform 估算 128,481 local groups、实际 131,069，为 1.02x；80MiB buffer
  中 payload 为 16MiB、`usage/estimate=20%`。差额来自按 hash slots、两倍 tuple
  容量及对齐进行的保守峰值估算，不是 NDV 失真；
- skew low 估算 1,999、实际 2,001，偏差 1.00x；
- low uniform 明细 Motion 为 2,000,000 rows，partial-row Motion 为 2,000 rows；
- 24 客户端并发全部成功：`successes=24 failures=0 waits=0 rejections=0`，相比历史
  固定 1GiB buffer 明显提高 admission 容量；
- GpuScan+GpuScan、GpuScan+GpuPreAgg 均结果匹配并排空资源；自适应 request 在
  admission 状态可见；受控 allocation failure 无泄漏、无部分结果，后续查询恢复；
- 三个 runner 分别输出本文第 5 节列出的成功标志。

上述证据满足本文第 1 节全部完成门槛，因此 M4b P0 在记录的单机共享 GPU 边界内
标记为完成。
