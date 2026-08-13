# Cloudberry GpuPreAgg M5a 共置 GROUP BY local-final 设计

状态（2026-08-13）：源码、静态检查和验收 runner 已实现；真实 GPU 验收需要在既有
单机 1 QD + 至少 2 Primary、所有 GPU Service 共享同一块 GPU 的环境执行。完成
真实验收前只称“实现完成”，不称“GPU 验收完成”。

## 1. 环境约束和结论边界

当前项目环境不支持把 Segment 部署到不同机器并为每台机器配置独立 GPU。后续
开发和优先级必须以以下实际拓扑为准：

- coordinator 和多个 Primary Segment 位于同一台主机；
- 每个 postmaster 有独立 GPU Service，但所有 Service 共享同一块物理 GPU；
- 可以验证 MPP locus、Motion 放置、CPU/GPU 结果、共享 GPU admission、并发、
  cancel、SIGHUP 和 SIGKILL/recovery；
- 可以比较 Motion 行数和单机执行时间，但不能形成多主机、多 GPU 线性扩展、
  跨主机负载均衡或每节点独立 GPU 性能结论。

因此近期不以多主机 GPU 协调、跨主机 GPU-Direct 或多 GPU 扩展为开发出口。
Redistribute final、GpuHashJoin 等可以做单机计划/正确性验证，但不能在当前环境宣称
多 GPU 性能收益。近期优先级为：共置 GROUP BY local-final、共享 GPU 公平
admission、HAVING、GpuPreAgg mixed quals、numeric/更多 aggregate，以及 AO/AOCO
可行性验证。

## 2. 目标

M4b 的每个 QE 已能产生 GPU partial aggregate，但此前无条件把 partial rows 通过
Gather Motion 发送到一个 QE，再执行一次 CPU final aggregate。M5a 对可以证明
GROUP BY keys 覆盖输入完整分布键的查询增加以下路径：

```text
每个 QE：GpuScan -> GpuPreAgg partial -> CPU local final
```

同一个全局 group 只可能位于一个 Segment，因此 local final 已经是全局正确结果，
不需要在 GpuPreAgg 和 CPU final 之间创建 Gather Motion。查询结果若需要发送给 QD，
上层仍可创建结果收集 Motion；M5a 消除的是 **pre-final Gather**，不是禁止计划顶层
的结果收集。

非共置 GROUP BY 和无 GROUP BY 聚合保持原路径：

```text
各 QE GpuPreAgg partial -> Gather Motion -> 单一 CPU final
```

## 3. Planner 实现

`__try_add_xpupreagg_normal_path()` 已使用
`cdbpathlocus_collocates_tlist()` 判断 GROUP BY keys 是否覆盖输入 Hashed locus。
M5a 将判断结果和输入 locus 保存到 `xpugroupby_build_path_context`。

`__buildXpuPreAggCustomPath()` 使用
`cdbpathlocus_pull_above_projection()` 验证分布键仍存在于 partial target：

- 投影后仍是 Hashed locus：保留该 locus，允许 local final；
- 投影无法保留分布键：降级为 Strewn，并回到 Gather-final；
- DISTINCT、无 GROUP BY、非共置 GROUP BY 均不启用 M5a。

`try_add_final_groupby_paths()` 对共置 GROUP BY 跳过 SingleQE Motion，并用每 QE
`num_groups` 计算本地 CPU final aggregate 成本；其他路径仍使用全局
`final_num_groups` 并创建原有 Gather Motion。

M4b 的“partial rows 达到输入 50% 则拒绝”规则是针对无法有效减少 Motion 的形状。
共置 M5a 不存在 pre-final Motion，因此不应用固定 50% gate，而是让完整 GPU、CPU
和上层路径成本参与普通 planner 竞争。

## 4. 正确性边界

只有以下条件全部满足才使用 local final：

1. PostgreSQL planner，`optimizer=off`；
2. 普通分布式非分区 heap；
3. device-only GpuScan 和当前 GpuPreAgg aggregate/type whitelist；
4. 存在非空 GROUP BY；
5. 输入 locus 是 Hashed，且 GROUP BY keys 覆盖完整分布键；
6. partial target 投影后仍能表达完整 Hashed locus。

以下形状必须保留 Gather-final 或原生计划：无 GROUP BY、GROUP BY 不覆盖完整分布
键、HashedOJ/Strewn locus、DISTINCT、mixed host/device quals、HAVING、numeric、
AO/AOCO、分区表和 ORCA。

## 5. 验收

`cloudberry/demo/setup.sql` 创建 `pgstrom_mvp_colocated`，按 `dist_key` 分布。runner
`run_gpupreagg_m5a.sh` 在普通 planner 成本下验证：

- `GROUP BY dist_key` 自动选择 GpuPreAgg；
- CPU final 与 GpuPreAgg 之间没有 Gather Motion；
- `GROUP BY grp` 仍在 CPU final 与 GpuPreAgg 之间保留 Gather Motion；
- 两种查询连续规划结果稳定，并分别匹配 CPU baseline；
- `EXPLAIN ANALYZE` 返回 QE 的 GpuPreAgg actual groups/bytes 统计；
- 至少两个正常 preferred Primary 参与验收。

执行命令：

```bash
PGDATABASE=pgstrom_mvp \
PGSTROM_GPUPREAGG_M5A_REPEAT=3 \
./gpcontrib/pg_strom/cloudberry/demo/run_gpupreagg_m5a.sh
```

成功标志：

```text
Cloudberry GpuPreAgg M5a colocated local-final acceptance passed
```

真实 GPU 通过后还应复用 GpuPreAgg cancel、SIGHUP/SIGKILL 和共享预算矩阵完成
故障后回归，且不得把单机共享 GPU 数据外推为多机性能结论。
