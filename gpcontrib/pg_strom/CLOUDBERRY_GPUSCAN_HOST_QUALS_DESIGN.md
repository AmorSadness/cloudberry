# Cloudberry GpuScan 混合 Host/Device Quals 设计

> 前置基线：`CLOUDBERRY_GPUSCAN_OBSERVABILITY_RECOVERY_MILESTONE.md`  
> 开发日期：2026-08-05  
> 当前状态：代码与无 GPU 静态检查阶段；真实双 Primary GPU 验收待完成

## 1. 目标

在现有普通分布式 heap GpuScan 范围内，允许同一个扫描同时包含：

- 至少一个可以编译为 GPU device code 的过滤条件；
- 一个或多个只能由 QE backend 执行的 host 条件。

典型查询为：

```sql
SELECT id, amount
FROM fact
WHERE amount >= 1000.00       -- device qual
  AND payload ~ '^cloudberry'; -- host qual
```

GPU Service 先返回满足 device quals 的 tuple，随后每个 QE backend 使用
`ExecQual()` 执行 host quals，最后通过 Motion 汇总结果。

本阶段不允许纯 host-only GpuScan。没有 device qual 的查询继续使用 Cloudberry
原生扫描路径，因为它不会获得 GPU 过滤收益，也不在本阶段成本和故障边界内。

## 2. 能力开关与边界

新增 Cloudberry 专用实验 GUC：

```text
pg_strom.cloudberry_enable_host_quals = off
```

它是 `PGC_USERSET`，默认关闭：

- `off`：保持前一里程碑行为，任何混合或纯 host-only 条件都不生成 GpuScan；
- `on`：允许至少含一个 device qual 的混合路径；
- 无论取值如何，没有 device qual 都不生成 GpuScan。

其余边界保持不变：PostgreSQL planner、普通分布式非分区 heap、GPU Service
ready、非 ORCA、非 AO/AOCO、非 replicated/coordinator-local；不开放分区、
GpuJoin、GpuPreAgg、GpuSort、GpuCache、GPU-Direct 或 DPU。

## 3. 现有执行链复用

PG-Strom 上游已有 host/device qual 的完整基础链路，Cloudberry MVP 之前只在
建路径时主动禁止它：

1. `buildSimpleScanPlanInfo()` 使用 `pgstrom_xpu_expression()` 将 restriction
   拆成 `scan_quals` 和 `host_quals`；
2. 成本模型先计算 device qual 的执行成本和选择率，再按 GPU 返回 tuple 数计算
   DMA 与 host qual CPU 成本；
3. `gpuscan_build_projection()` 把 host qual 引用的 Var 加入 device 输出，避免
   QE 执行 host filter 时缺列；
4. `PlanXpuScanPathCommon()` 将 host quals 放入标准 `plan.qual`；
5. Cloudberry QD-to-QE plan mutation 会按核心 Plan 字段重写 `plan.qual`；
6. `pgstromExecTaskState()` 对 GPU 返回 tuple 调用 `ExecQual()`，不通过的 tuple
   计入 `Rows Removed by Filter`；
7. device quals 仍通过 `custom_exprs` 下发并显示为 `GPU Scan Quals`。

本次代码改动只把 Cloudberry 的 `allow_host_quals` 参数接到新 GUC，不修改表达式
分类、device code、tuple ABI 或 executor 循环。

`pgstromPlanInfo.host_quals` 在扩展私有数据中保留上游布局，但 QE 执行的权威表达式
是经过 Cloudberry 核心重写的 `CustomScan.scan.plan.qual`。核心仍不解释或 mutation
`custom_private`，保持原有扩展私有数据边界。

## 4. 成本与 MPP 语义

Cloudberry `RelOptInfo` 保存全局统计，GpuScan Path 表达每 QE 工作量。现有成本
代码先按 `planner_segment_count()` 缩放 tuple/page，再依次应用：

1. device qual cost 和选择率；
2. GPU-to-host tuple 传输成本；
3. host qual CPU cost 和选择率；
4. host projection cost。

startup cost 仍由每个 QE 独立承担。混合条件不改变 locus、Motion、rescan、
parallel worker 或 QD/QE Service 生命周期。

本里程碑只验证成本计算没有丢失 host qual，并不形成性能结论；demo 继续使用
`enable_seqscan=off` 暴露合法路径。

## 5. 验收矩阵

`cloudberry/demo/run_demo.sh` 增加以下检查：

- GUC 默认/显式关闭时，device + regexp 混合查询回退原生计划；
- GUC 开启时，计划同时包含 `Custom Scan (GpuScan)`、`GPU Scan Quals` 和
  标准 `Filter`；
- 纯 regexp host-only 查询在 GUC 开启时仍不生成 GpuScan；
- 均匀表、单 Segment 倾斜表和仅一个非空 QE 的小表分别比较 CPU/GPU 签名；
- skew/small 表覆盖 NULL 与 host regexp 的三值逻辑；
- prepared statement 覆盖 device 参数和 host regexp 参数；
- LIMIT、重复执行和 lateral/rescan 形状可完成；
- 原 ORCA、AO、AOCO、分区及故障恢复边界不退化。

静态测试保护 GUC、默认关闭、至少一个 device qual 约束及上述 runner 入口。

## 6. GPU 验收出口

在真实 GPU 环境中至少使用 1 QD + 2 Primary，依次执行：

```sh
gpcontrib/pg_strom/cloudberry/test_static_mvp.sh

PGDATABASE=pgstrom_mvp \
PGSTROM_MVP_REPEAT=3 \
./gpcontrib/pg_strom/cloudberry/demo/run_demo.sh

PGDATABASE=pgstrom_mvp \
PGSTROM_MVP_CANCEL_CYCLES=3 \
./gpcontrib/pg_strom/cloudberry/demo/run_query_cancel.sh
```

还应重新运行 SIGHUP 与 SIGKILL recovery runner，证明新增 planner 路径没有改变
Service 失败传播。全部通过后才能把本设计状态更新为真实 GPU 已验收；在此之前
该能力应描述为“默认关闭、源码完成、待 GPU 验收的实验特性”。
