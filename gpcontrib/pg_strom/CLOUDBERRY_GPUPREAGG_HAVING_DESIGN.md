# Cloudberry GpuPreAgg M5b HAVING 设计

状态（2026-08-13）：源码、静态检查和真实 GPU 验收 runner 已实现；待在单机
1 QD + 2 Primary、所有 GPU Service 共享同一块 GPU 的环境完成真实 GPU 验收。
验收完成前只称“实现完成”，不称“HAVING GPU 验收完成”。

## 1. 目标和执行语义

M5b 支持由 grouping key、当前 GpuPreAgg whitelist 中的 aggregate，以及普通 CPU
标量/布尔表达式构成的 HAVING。HAVING 不下推到 GpuPreAgg，也不作用于 GPU partial
state；aggregate 先完成全局语义上的 CPU final，再由该 final `Agg` 节点执行 HAVING
filter。

三种放置为：

```text
共置 GROUP BY：
  每个 QE GpuPreAgg partial -> CPU local final + HAVING

非共置 GROUP BY：
  各 QE GpuPreAgg partial -> Gather Motion -> 单一 CPU final + HAVING

无 GROUP BY：
  各 QE GpuPreAgg partial -> Gather Motion -> CPU global final + HAVING
```

共置路径正确的前提沿用 M5a：GROUP BY 覆盖完整输入分布键，同一个全局 group 只在
一个 Segment 上。顶层仍可有把最终结果送到 QD 的结果收集 Motion。

## 2. 表达式替换

Cloudberry query guard 同时遍历 target list 和 `parse->havingQual`，HAVING 中出现的
aggregate 必须通过与输出列相同的 count/sum/min/max、整数/浮点类型白名单。只在
HAVING 中出现而不在 SELECT list 中出现的 aggregate 同样生成所需 GPU partial
action。

`replace_expression_by_agg_altfuncs()` 把 HAVING aggregate 改写为 CPU final 对 GPU
partial state 的合并表达式，例如：

```text
count(*)       -> pgstrom.fcount(pgstrom.nrows())
sum(int8)      -> pgstrom.sum_int64(pgstrom.psum64(...))
min(int4)      -> pgstrom.min_i4(pgstrom.pmin(...))
```

改写后的 qual 只传给 `create_agg_path(..., havingAggQuals, ...)`。Cloudberry 始终保留
CPU final aggregate，因此不构造、不附加上游 GPU-final projection HAVING qual。

## 3. NULL 和三值逻辑

HAVING 由 Cloudberry/PostgreSQL CPU `Agg`/`ExecQual` 执行，遵循原生三值逻辑：

- 条件为 TRUE 的 group 保留；
- FALSE 或 UNKNOWN 的 group 丢弃；
- 空输入的 `count(*)` 为 0，`sum/min/max` 为 NULL；
- `HAVING sum(x) IS NULL` 可保留全 NULL 或空输入结果；
- `HAVING sum(x) > 0` 对 NULL 得到 UNKNOWN 并丢弃结果。

M5b 不在 GPU 端重新实现布尔或 NULL 语义。

## 4. 支持和回退边界

支持：

- 共置、非共置和无 GROUP BY GpuPreAgg；
- HAVING 引用 grouping key；
- HAVING 引用 SELECT list 中已有或仅 HAVING 使用的受支持 aggregate；
- `IS NULL`、比较、AND/OR 和其他可由 CPU 执行的普通表达式。

继续安全回退到原生聚合：

- HAVING 中的 aggregate FILTER、DISTINCT 或 aggregate ORDER BY；
- numeric 或其他未进入 whitelist 的 aggregate/type；
- grouping sets、mixed host/device scan quals、AO/AOCO、分区表和 ORCA；
- 任何无法完成 alternative aggregate 替换的表达式。

回退必须发生在 path 创建阶段，不得等到 executor 报错。

## 5. 验收

`cloudberry/demo/setup.sql` 为 `pgstrom_mvp_colocated` 增加 `nullable_metric`，并让
`grp=0` 的所有输入均为 NULL。`run_gpupreagg_having.sh` 验证：

1. 普通成本下，共置和非共置 HAVING 稳定自动选择 GpuPreAgg；
2. HAVING `Filter` 位于 CPU final aggregate，GpuPreAgg 节点不执行 HAVING；
3. 共置路径没有 pre-final Gather，非共置路径保留 Gather-final；
4. grouping key、输出 aggregate 和仅 HAVING 使用 aggregate 的表达式替换正确；
5. NULL/UNKNOWN、全 NULL group 和空输入全局 aggregate 与 CPU baseline 一致；
6. FILTER、DISTINCT 和 numeric HAVING aggregate 保持原生计划；
7. M5a、M4b、共享 GPU、cancel 和 failure-recovery 回归不退化。

空输入形状因正常成本下 GPU setup 不经济，runner 只对该形状使用明确标注的
correctness-only 成本；分组正向用例保持普通 planner 成本。

执行命令：

```bash
PGDATABASE=pgstrom_mvp \
PGSTROM_GPUPREAGG_HAVING_REPEAT=3 \
./gpcontrib/pg_strom/cloudberry/demo/run_gpupreagg_having.sh
```

成功标志：

```text
Cloudberry GpuPreAgg HAVING acceptance passed
```

本里程碑仍只形成单机多 Segment 共享单 GPU 的计划、结果、资源和故障恢复结论，
不形成多主机或多 GPU 性能结论。
