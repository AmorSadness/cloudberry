# Cloudberry GpuPreAgg P1-1 mixed host/device quals 设计

状态（2026-08-14）：源码、静态检查、设计和真实 GPU 验收 runner 已实现；待在
单机 1 QD + 2 Primary、所有 GPU Service 共享同一块物理 GPU 的环境完成真实 GPU
验收。验收前只称“实现完成”，不称“P1-1 GPU 验收完成”。

## 1. 目标与语义边界

P1-1 允许同一 WHERE 中同时存在 GPU 可执行和 CPU-only 条件时使用 GpuPreAgg。
例如 `id > 0` 在 GPU 执行，而 `payload ~ '^[0-7]'` 由 QE CPU 执行。host qual 必须
发生在 partial aggregation 之前：

```text
base heap
  -> GpuScan：device qual
  -> QE CPU ExecQual：host qual
  -> ROW KDS
  -> GpuPreAgg：partial aggregation
  -> [Gather Motion]
  -> CPU final aggregate [+ HAVING]
```

禁止把 host qual 放在 GpuPreAgg 的 `plan.qual` 上。GpuPreAgg 返回的是 partial state，
此时再按明细列表达式过滤既无法取值，也会改变 count/sum/min/max 语义。

功能继续由默认关闭的 `pg_strom.cloudberry_enable_host_quals` 控制。关闭时 mixed quals
保持原生 aggregate；只有 host qual、没有 device qual 时也保持原生路径。

## 2. Planner 设计

GpuScan 在 opt-in GUC 开启且同时存在 device/host quals 时，除普通候选路径外，为
GpuPreAgg tracker 保存一个不进入 baserel pathlist 的完整物理行目标路径：

- 子 GpuScan 负责 device qual、CPU host qual 和物理行投影；
- 完整物理 target 保持 base attribute number 与 ROW KDS 列号一致；
- 含 dropped/missing column、无法构造 physical target 时安全回退；
- GpuPreAgg 不再重复继承 child 的 scan/host quals 或直接 base-scan 成本；
- GpuPreAgg CustomPath 将该 GpuScan 作为 source custom plan，输出 locus 仍沿用 M5a
  的共置证明，否则保持 Gather-final。

`DEVTASK__SCAN_OUTER_CHUNKS` 明确标记这种两阶段输入，避免把 source custom plan
误当成 GpuJoin inner relation。`EXPLAIN` 输出：

```text
Pre-Aggregation Input: CPU host-filtered GpuScan rows
```

## 3. Executor 设计

子 GpuScan 仍使用既有 `pgstromExecTaskState()`：GPU 返回 device-qualified rows，随后
标准 `ExecQual()` 执行 host filter。父 GpuPreAgg 的 source callback 读取子 plan，按
最多 `PGSTROM_CHUNK_SIZE` 组成 `KDS_FORMAT_ROW`：

- row index 从 KDS 头部增长，MinimalTuple 从尾部反向写入；
- 单行跨 chunk 时复制为 pending tuple，下一批首先消费；
- 单个 tuple 本身超过 chunk 上限时明确报 `PROGRAM_LIMIT_EXCEEDED`；
- cancel、rescan 和 executor end 都释放 pending tuple，并 rescan/end 子 plan；
- 父任务不创建第二个 heap scan descriptor，只创建自己的 GPU session/final buffer。

这条路径会产生 GPU→CPU→GPU 的额外明细数据传输。P1-1 的出口是执行位置和结果
正确性，不承诺 mixed quals 的性能收益；后续可以单独研究设备可执行表达式覆盖或
流水化传输优化。

## 4. 支持与回退

支持范围：

- PostgreSQL planner、普通分布式非分区 heap；
- 至少一个 device qual 和至少一个 CPU host qual；
- M5a 共置、Gather-final、全局 aggregate；
- 当前 count/sum/min/max 整数/浮点白名单；
- M5b CPU-final HAVING 与 mixed WHERE 组合。

继续回退：

- GUC off 或只有 host qual；
- 无法构造完整物理 target；
- AO/AOCO、分区、ORCA、numeric、DISTINCT/FILTER 和现有其他 guards；
- 多主机、多 GPU 性能或调度能力不在结论范围。

## 5. 验收

执行：

```bash
PGDATABASE=pgstrom_mvp \
PGSTROM_GPUPREAGG_MIXED_REPEAT=3 \
./gpcontrib/pg_strom/cloudberry/demo/run_gpupreagg_mixed_quals.sh \
  2>&1 | tee /tmp/pgstrom-gpupreagg-mixed.log
```

runner 验证：

1. 共置、非共置、无 GROUP BY 和 mixed WHERE + HAVING 稳定生成 GpuPreAgg；
2. GpuScan 同时显示 `GPU Scan Quals` 和 regex CPU `Filter`；
3. host filter 位于 GpuScan 子节点，严格早于 GpuPreAgg；
4. 共置路径无 pre-final Gather，其他路径保留 Gather-final；
5. 四组结果 digest 与纯 CPU baseline 一致；
6. opt-in GUC off 和 host-only 查询安全保留原生 aggregate。

成功标志：

```text
Cloudberry GpuPreAgg mixed host/device quals acceptance passed
```

本里程碑仍只形成单机多 Segment 共享单 GPU 的计划、结果、资源和恢复结论，不形成
多主机或多 GPU 性能结论。
