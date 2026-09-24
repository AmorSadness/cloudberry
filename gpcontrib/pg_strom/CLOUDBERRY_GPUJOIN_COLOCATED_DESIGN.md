# Cloudberry 受限共置 GpuJoin：设计与验收

状态：**源码开发完成，无 GPU 验收待完成**（2026-09-24）。当前环境没有 CUDA
Toolkit/GPU；无 GPU 检查不能证明设备编译、QD→QE 计划下发、SQL 结果或故障恢复正确。
本功能不沿用 2026-08 的 GpuScan/GpuPreAgg 历史验收结论。

## 1. 目标与首版边界

在 PostgreSQL planner (`optimizer=off`) 下，为两张普通 hash 分布 heap 表添加
默认关闭的、每个 QE 独立执行的 INNER Hash Join 候选。实现复用 upstream
GpuJoin 内核、inner KDS、CPU hash 构建和 GPU Service 协议，不实现新 CUDA 算法。
当前验证拓扑仍是单机、至少两个 Primary、一个 UID/PID namespace、共享一块 GPU。

| 项目 | 首版规则 |
| --- | --- |
| 开关 | `pg_strom.enable_gpujoin=on`，Cloudberry 默认 **off**；同时要求 `pg_strom.enabled=on`、`pg_strom.enable_gpuhashjoin=on` |
| 表 | 两个 `RELOPT_BASEREL` 普通 heap，hash 分布，分布 Segment 数等于当前完整集群 Segment 数 |
| 连接 | planner 中的 `JOIN_INNER`，当前 query level 的 `all_baserels` 恰为两个；允许 self join 的不同别名 |
| 共置证明 | 全部分布键逐项显式等值连接，键顺序、类型、hash opclass、Segment 数相同 |
| 分布键类型 | 同类型 `smallint`、`integer`、`bigint`，包括复合键；只接受直接 Var，不接受 cast/表达式或仅依赖等价类的推导 |
| 谓词 | 两侧基表限制与 JOIN 条件均须通过设备表达式检查；拒绝 volatile、subplan、pseudoconstant；额外设备 residual 条件允许；额外 hash 等值键也要求两侧类型一致 |
| 输入 | outer 使用融合 heap 扫描；inner 固定为 QE 原生、无参数、无并行 worker 的 Seq Scan |
| 无 WHERE | 支持，私有 scan builder 不改变独立 GpuScan 的准入规则；不要求 `cloudberry_enable_unfiltered_agg` |
| 输出 | 保守标记为 Strewn；上层需要收集/重分布时由原生 planner 创建 Motion |
| inner 上限 | `pg_strom.cloudberry_gpujoin_max_inner_size`，默认 `256MB`，范围 `1MB..4096MB`，每 QE 的序列化 inner hash buffer |

明确保留原生计划：LEFT/RIGHT/FULL、SEMI/ANTI、非等值/笛卡尔连接、非共置连接、
缺少复合分布键、键顺序或 opclass/类型不一致、random/replicated/coordinator-local 表、
分区父表/叶表、传统继承、AO/AOCO、foreign/Arrow、RLS/security quals、TABLESAMPLE、
参数化输入、三个及以上基表的同层连接、ORCA、行锁和非 SELECT 命令。

限制针对 **planner 最终形状**。例如 SQL LEFT JOIN 被优化器合法简化成 INNER JOIN 后，
可以满足本功能规则；不能只按 SQL 文本判断是否必须回退。投影、ORDER BY 和 CPU
聚合可以位于 GpuJoin 上方。首版不注册 join 结果为后续 GPU leaf，因此不支持多层
GpuJoin 融合或 Join+GpuPreAgg 融合。GiST、nested-loop、pinned inner、partitionwise
join 不会由本入口创建，修改其上游开关也不会绕过限制。
后续新增的默认关闭 GpuSort 可融合到符合条件的共置连接结果中；其独立限制及待验收项见
[CLOUDBERRY_GPUSORT_DESIGN.md](CLOUDBERRY_GPUSORT_DESIGN.md)。

## 2. 共置证明与计划

`cloudberry_gpujoin_base_supported()` 先检查表、分布和谓词；
`cloudberry_gpujoin_colocated()` 对每一个物理分布键位置检查：

1. 两侧 policy 的键数和 Segment 数相同，当前位置 opclass OID 相同。
2. JOIN restriction 中存在两个直接 Var，分别指向这两个基表的对应物理属性。
3. 两侧同为 int2/int4/int8 中的同一类型。
4. 运算符是该整数类型的原生等值运算符，且是分布 hash opfamily 的等值成员，
   并被 planner 标记为 hash join operator。
5. 所有键均满足，才证明一个可能匹配的行对必定位于同一 QE。

不以表名、键名相似或“两个输入都是 Hashed”代替上述证明。NULL 行可能被分布到某些
QE，但普通 `=` 不把两个 NULL 判为相等，仍由 join qualifier 决定是否输出。
inner hash bucket 保留所有 tuple，不做唯一化；有 m 个 outer 匹配 n 个 inner 时应输出
m×n 行。`IS NOT DISTINCT FROM` 不满足本版共置等值准入。

计划形态示意（EXPLAIN 的节点细节以实际版本为准）：

```text
Gather Motion / 原生上层算子
  Custom Scan (GpuJoin) on outer_heap
    Cloudberry Join: Colocated INNER hash join
    Inner Input: Native QE heap scan; no Motion
    GPU Join Quals / GPU Hash Keys ...
    Seq Scan on inner_heap
```

GpuJoin 自身融合 outer scan，因此不要求出现子节点 GpuScan。inner 子树不得含 Motion、
CustomScan、并行或参数化路径。结果投影可能去掉分布键，首版采用 Strewn 避免上层错误
沿用 Hashed locus；代价是可能产生本可避免的上层 Motion，优化留待后续。
`custom_plans`、`custom_exprs` 和 `custom_scan_tlist` 继续走既有 Cloudberry 计划重写。

## 3. 成本与内存

outer scan 沿用既有每 QE 成本模型；join 输出全局估算行数除以 policy Segment 数。
inner Seq Scan 的行数和成本已经是每 QE 值，不二次除 Segment 数。
CPU inner 预加载/hash 构建、GPU join 和结果传回成本沿用上游模型。
`Path.memory` 按 **bytes** 记录估算 inner 大小，初始化 locus、hazard、rescannable、
sameslice_relids；QE 内 parallel workers 固定为零。

大小上限 GUC 显式标记 `GUC_GPDB_NEED_SYNC`，确保 QD 的 SET/事务恢复同步到 QE，
规划与执行使用一致的配置。

规划估算为 `8192 + inner_rows * (MAXALIGN(projected_width) + 96)` bytes。
这是粗略准入估算，不是严格内存预留或性能校准。估算超过上限时不创建 GPU path。
实际预加载逐行计算 hash KDS 元数据、hash slots、row indexes、tuple usage 和页对齐，
在映射 host inner buffer 前再检查实际总长；超限抛出明确错误：

```text
Cloudberry GpuJoin inner buffer exceeds cloudberry_gpujoin_max_inner_size
```

实际超限不重新执行 CPU 查询；调用方应调整上限或关闭 GpuJoin 后重试。此时尚未打开
GPU join session，不应输出 join 结果。该限制不等于 QE 总 RSS 上限：暂存 MinimalTuple、
TOAST detoast、元数据以及 host/device 的多个副本会占用额外内存；不支持 spill。

Service 将 inner KDS 通过 `allocGpuQueryBuffer(..., GQBUF_KIND__GPUJOIN_INNER_BUFFER)`
分配（日志 `kind=j`），使用现有 host-wide FIFO 预算：先预留，再 CUDA 分配；失败回滚；
最后一个 session 引用释放时 `cuMemFree` 并归还额度。task/pool buffer 仍走已有预算。
这次不增加另一份预算账本、不改变 SQL catalog 6.3 或当前 ledger v2。
从历史 ledger v1 升级仍须遵循 `CLOUDBERRY_DEVELOPMENT.md` 的全部 Service 停止流程。

## 4. 执行、rescan 与故障生命周期

- 原生 inner scan 和融合 outer heap scan 使用正常 snapshot；不引入跨 QE 数据交换。
- GpuJoin 每次打开 session 使用 PID + 单调 execution ID，高位区分既有 plan-node ID。
  不能用可重复的 plan_node_id 识别 prepared execution/rescan 的 inner 数据。
- rescan 关闭旧连接、重置计数和子计划，解除旧 host mmap，并创建新的共享内存 handle；
  避免尚在清理的旧 Service 会话读取被下一次执行覆盖的映射。
- 正常结束沿用 ResourceOwner/EndTaskState 清理；取消、断连、预算拒绝和 Service
  崩溃回收仍需逐项验证，不能仅凭已有 GpuPreAgg 测试推定通过。
- join inner setup 的失败路径清空已发布的 host mapping 指针，避免局部清理后
  query-buffer destructor 再次解除同一映射。
- execution ID 不允许回绕；极限耗尽时明确报错并要求重新连接。

## 5. 当前无 GPU 验证

在仓库根目录执行：

```bash
bash gpcontrib/pg_strom/cloudberry/test_development.sh
PG_CONFIG=/home/mkm/cloudberry-install/bin/pg_config \
  bash gpcontrib/pg_strom/cloudberry/check_gpujoin_host_syntax.sh
```

开发时上述检查通过：历史静态规则、operator source contracts、7 项 GpuJoin
源代码边界/计划验收器测试、shell/Python 语法、FIFO CPU 不变量，以及
`gpu_join.c / gpu_scan.c / executor.c / main.c` 的 Cloudberry 主机 C/API 语法。
第二个脚本生成临时 opaque CUDA 声明，不修改仓库头文件，不产生可安装二进制；
它不覆盖 `gpu_service.c` 的完整 CUDA API 编译，也不是 SDK、链接或设备代码构建。

## 6. GPU 环境自动验收

目标环境要求：完整 CUDA SDK，扩展在 QD 和所有 Primary 安装并 preload，数据库扩展
catalog 6.3，所有 Service 使用相同本次源码/设备代码；使用**专用验收数据库**。
runner 创建随机 schema 和 fixture，结束后只删除该 schema；不重启 Service。

```bash
make -C gpcontrib/pg_strom/src \
  PG_CONFIG=/path/to/cloudberry/bin/pg_config PGSTROM_WITH_ARROW=0
make -C gpcontrib/pg_strom/src \
  PG_CONFIG=/path/to/cloudberry/bin/pg_config PGSTROM_WITH_ARROW=0 install
# 按现有集群流程在全部实例部署/重启后：
PGDATABASE=pgstrom_mvp python3 \
  gpcontrib/pg_strom/cloudberry/demo/run_gpujoin_regression.py
# 成本选择单独评估；仍要求正向用例产生 GpuJoin：
PGDATABASE=pgstrom_mvp python3 \
  gpcontrib/pg_strom/cloudberry/demo/run_gpujoin_regression.py --normal-planner
# 独占、空闲验收集群，superuser；受控的预留后分配失败：
PGDATABASE=pgstrom_mvp python3 \
  gpcontrib/pg_strom/cloudberry/demo/run_gpujoin_regression.py --fault-injection
```

默认模式把原生 join 方法设为不推荐并降低 GPU 成本，以暴露候选用于正确性检查；
这不是性能测试。`--normal-planner` 不改变 join 成本开关，正向路径未被选中会失败，
需检查估算和数据规模，不能把原生执行算作 GPU 验收成功。

runner 保存 revision、diff、源码 hash、版本/Service 元数据、EXPLAIN ANALYZE JSON、
CPU/GPU 完整排序多重集结果、并发资源快照及错误输出。每个普通 case 重复三次，
关闭 CPU fallback，正向要求 GpuJoin 且子树无 Motion；负向要求没有 GpuJoin。
不使用 DISTINCT 或仅行数比较，因此不会漏掉重复行数量或 NULL 内容错误。

已提供自动 case：

- 单键、复合键、三种整数键、反向等值表达式、self join、额外 join residual、
  无 WHERE、双侧 device WHERE、投影去掉分布键、重复键/NULL、空表输入。
- 缺少复合键、键顺序/数量不同、表达式键、跨类型、非分布键、NULL-safe equality、
  外连接/SEMI/ANTI、random/replicated、分区、AO、host-only WHERE、多表、ORCA、关闭开关。
- 同一个 backend 内 generic prepared 多次执行、修改 inner 候选数据后再执行，
  与 CPU 对照（事务回滚，保持 fixture）。
- 先缓存小表 GPU 计划，再插入数据使实际 inner buffer 超过 1MB：要求精确超限错误、
  无部分结果，随后恢复查询正确。普通预算错误不满足此 case。
- 默认 4 客户端同时执行并比较结果、等待 clients/queued/active 清零并保存资源快照。
- 显式 `--fault-injection` 使用既有 superuser injection，在 inner buffer 预算预留后
  故意失败；要求精确错误、无部分结果、预留回到暖机基线和恢复查询成功。

`run_development_suite.sh` 已加入本 runner。历史单表阶段显式关闭 GpuJoin。
`SELECTED_CASES_PASSED` 只代表已选 case；`*.SKIPPED` 保留未执行项目，不能标记全部验收。

## 7. 仍需执行的人工/专项验收门槛

| 门槛 | 方法和必须保留的证据 |
| --- | --- |
| 完整构建 | 目标 Cloudberry + CUDA 重新 build/install，host 和 fatbin 一致；保留构建日志，不能使用旧 `.o/.so` 代替 |
| 多 QE 实际执行 | 每个 Primary 有 GpuJoin 实际执行/Service submitted 增量；检查没有只在一个 QE 处理全表或未执行的正向节点 |
| 分布证明反例 | 同类型不同 hash opclass、不同 policy Segment 数、AOCO/foreign、继承、分区叶、RLS、TABLESAMPLE、参数化路径；全保留原生计划 |
| 数据边界 | int2/int4/int8 极值、复合键任一列 NULL、严重倾斜、无匹配、TOAST/宽 payload、多批输入；关闭 CPU fallback，逐项比较 CPU 多重集 |
| MVCC | 两会话验证未提交 insert/update/delete 不可见及提交后的新 snapshot；不能只测试静态表 |
| 实际 rescan | 构造不能 materialize 的重复执行上层，EXPLAIN ANALYZE 中 GpuJoin Actual Loops > 1；重复 EXECUTE 不等于 rescan；若 planner 无法产生该计划则记未覆盖 |
| query cancel | 扩大两张共置表，长查询期间从另一会话 `pg_cancel_backend(pid)`；分别覆盖 CPU inner 预加载与 GPU 活跃阶段，确认 query cancel 错误、资源排空、随后 CPU/GPU 一致 |
| 断连 | 在上述两个阶段断开客户端；检查 shm 对象、clients、queue、active、query buffer 的回收 |
| 预算/FIFO | 调低专用集群的统一预算并配置正等待时间，运行多客户端/大 inner；必须观察 `kind=j` 预留/等待/拒绝，不能以 CUDA OOM 替代预算拒绝 |
| 组合并发 | Join+Join、Join+Scan、Join+PreAgg；结果正确，无部分结果，长期多轮 reservation 不增长；暖机 pool 与泄漏需通过分配/释放日志区分 |
| SIGHUP / SIGKILL | 显式选择一个 Primary 的 GPU Service PID（不是 postmaster），在 active join 时执行；每种至少三轮，检查 generation 更新、stale reclaim（SIGKILL）、新 Service ready、恢复查询正确 |
| 故障后回归 | 重跑新 join runner 与完整 development suite，检查所有 `.SKIPPED`，已验收单表路径不退化 |

取消与故障测试可按以下会话模板操作（先确认 EXPLAIN 有 GpuJoin，并把查询替换为足够长的共置查询）：

```sql
-- 会话 A：记录 PID，随后启动长查询
SET optimizer=off;
SET pg_strom.enable_gpujoin=on;
SET pg_strom.enable_gpuhashjoin=on;
SET pg_strom.cpu_fallback=off;
SELECT pg_backend_pid();
EXPLAIN (VERBOSE) SELECT a.k,a.v,b.v FROM join_a a JOIN join_b b ON a.k=b.k;
SELECT a.k,a.v,b.v FROM join_a a JOIN join_b b ON a.k=b.k;

-- 会话 B：先观察实际阶段，再取消指定会话
SELECT content_id,service_pid,service_generation,ready,
       active_clients,queued_commands,active_commands,
       local_reserved_bytes,shared_reserved_bytes,budget_waits,budget_rejections
FROM pgstrom.gpu_service_status ORDER BY content_id,gpu_id;
SELECT pg_cancel_backend(<会话A的PID>);
```

Service 重启/杀进程具有破坏性，只在专用验收集群明确安排后按既有恢复流程执行。
本 runner 不自动启用。取消前必须观察执行阶段；快速结束后再发 cancel 不能算取消验收。
资源判断应保存故障前、排空后和恢复后的快照，并核对 `kind=j` 分配与释放成对出现；
Service 崩溃场景则检查 ledger stale owner 回收，不能要求死进程输出释放日志。

## 8. 完成口径与后续方向

当前交付是默认关闭的受限实现、无 GPU 检查、可运行 GPU 验收入口及专项验收方法。
只有第 6 节自动 case 和第 7 节必要专项门槛留存真实证据后，才能标记该拓扑的 GPU 验收完成。
不承诺加速比、多机/多 GPU 扩展性、资源组公平性或通用 SQL Join 支持。
后续可单独扩展 LEFT JOIN、保留投影后可证明的 Hashed locus、更多键类型、原生 inner
路径选择和 Join+PreAgg；不得仅打开上游总开关跳过 Cloudberry 共置检查。
