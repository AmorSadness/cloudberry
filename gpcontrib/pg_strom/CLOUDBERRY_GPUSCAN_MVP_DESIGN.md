# Cloudberry GpuScan MVP 设计与演进总结

> 文档基线：Cloudberry `main` 分支，HEAD `bdf71dbac91722c2455d25f58949ea5f18ff2cf8`  
> 上游基线：PG-Strom v6.1，commit `4d12ef415759dc48cd4c1421565e9c694b7bd3f9`  
> 整理日期：2026-07-29

## 1. 结论

当前版本已经形成一个**功能正确、范围受控、具备可重复验收流程的 Cloudberry 单 Primary GpuScan MVP**。它可以在一个 Coordinator（QD）和一个 Primary Segment（QE）组成的单机 Cloudberry 集群中，对普通分布式 heap 表生成并实际执行 `Custom Scan (GpuScan)`，把可支持的过滤表达式和投影交给 GPU 执行，并通过 Motion 将 QE 结果返回 QD。

完整 demo 已验证：

- GpuScan 位于 QE slice，而不是只在 QD 上出现一个不可执行的伪计划；
- 无 LIMIT 和有 LIMIT 的实际 GPU 扫描均能完成；
- `bigint`、`integer`、`numeric` 和 `text` 投影/结果签名组合正确；
- CPU 与 GPU 的聚合签名一致；
- prepared statement、参数变化、重复执行和 lateral/rescan 形状可用；
- ORCA、AO、AOCO、分区表和含 host-only 正则条件的查询不会越过 MVP 边界生成 GpuScan；
- demo 最终返回码为 0；
- QD、QE 均加载与 Cloudberry 存储配置匹配的新 fatbin，并各自创建 16 个 task worker。

这个结论不等于“生产就绪”。当前版本没有证明多 Segment、多主机、并发资源隔离、故障自动恢复、长时间稳定性或性能收益，也没有开放 GpuJoin、GpuPreAgg、GpuSort、GpuCache、GPU-Direct 等上游完整能力。

## 2. 设计目标与基本策略

### 2.1 目标

MVP 的目标不是一次性移植 PG-Strom 的全部功能，而是打通最小、可验证的执行闭环：

1. 使用 Cloudberry 的 PostgreSQL planner 生成 GpuScan CustomPath/CustomScan；
2. 正确表达分布式 Path 的 locus、成本和每 QE 行数；
3. 让 QD 生成的 CustomScan 在 QD-to-QE 重写后仍保持合法；
4. 在 QE 中执行 heap 扫描，把设备可执行条件和投影交给 GPU Service；
5. 对尚未适配的表类型、优化器和表达式安全回退到 Cloudberry 原生路径；
6. 用 CPU/GPU 结果签名和负向边界测试证明正确性。

### 2.2 “先缩边界、再扩能力”

PG-Strom 上游面向单机 PostgreSQL，功能面很大。Cloudberry 是 MPP 数据库，QD/QE、Motion、分布策略和计划下发都会改变扩展的运行假设。因此 MVP 采用以下原则：

- 只注册经过 Cloudberry 验证的 GpuScan planner/executor 路径；
- 对未适配能力不做“尽量运行”，而是在初始化或规划阶段明确禁止；
- 对设备不能完整执行的条件不生成 GpuScan，避免在尚未验证的 host-qual 混合路径中产生错误结果；
- 对共享内存、后台 worker 和 device ABI 使用显式生命周期/配置判定，而不依赖“上游通常会初始化”的隐式前提；
- 用静态约束测试保护设计边界，用 GPU demo 保护端到端行为。

## 3. 总体架构

一次受支持的查询大致经过以下链路：

```text
客户端 SQL
   |
   v
QD：PostgreSQL planner（optimizer=off）
   |  set_rel_pathlist_hook
   |  为合格的分布式 heap 表构造 CustomPath(GpuScan)
   v
QD：生成 CustomScan + Motion
   |  cdbplan 递归重写 CustomScan 的计划/表达式字段
   v
计划下发到 QE slice
   |
   v
QE：CustomScan executor
   |  组织 KDS、设备表达式、投影和任务命令
   |  连接本 QE postmaster 所属的 PG-Strom GPU Service
   v
GPU Service：task worker -> CUDA stream/kernel -> fatbin
   |
   v
QE 返回 tuple -> Motion -> QD -> 客户端
```

QD 和 QE 都通过 `shared_preload_libraries='pg_strom'` 启动自己的 GPU Service。单机 MVP 中它们能看到同一块 GPU，但拥有独立进程、CUDA context、worker pool 和内存池配置。因此当前验收要求串行运行，不能把每个服务的 `gpu_mempool_max_ratio` 误认为跨进程的统一资源配额。

## 4. 核心设计

### 4.1 构建与依赖隔离

PG-Strom 不进入 Cloudberry 默认构建链，而是显式使用目标安装树的 `pg_config` 构建：

```sh
make -C gpcontrib/pg_strom/src \
  PG_CONFIG=/path/to/cloudberry/bin/pg_config \
  PGSTROM_WITH_ARROW=0
```

这样做有三个目的：

- 使用目标 Cloudberry 的 PostgreSQL 16 server headers 和 ABI；
- 避免构建机是否碰巧安装 Arrow/Parquet 改变产物依赖；
- 保持上游源码快照可识别，二进制版本标记固定为上游 hash 加 `cloudberry_mvp`，而不是错误使用外层 Cloudberry 仓库 hash。

`PGSTROM_WITH_ARROW=0` 时由 `arrow_stubs.c` 提供链接所需的最小符号。Arrow FDW 不会被规划器选中，主动调用相关能力会得到“不支持”错误，而不会出现缺失符号或静默启用。

### 4.2 Cloudberry API/ABI 适配

Cloudberry 与上游 PostgreSQL 16 在若干 planner/executor API 上存在差异，例如：

- `add_path()` 额外需要 `PlannerInfo *root`；
- `compute_parallel_worker()`、`clause_selectivity()`、`create_agg_path()` 等接口参数不同；
- planner hook 带 `OptimizerOptions`；
- `ExecSetParamPlan()`、`HeapTupleSatisfiesVisibility()` 等 executor/heap API 不同；
- `InstrStopNode()` 的参数类型/语义不同。

适配通过 `GP_VERSION_NUM` 条件编译完成，使同一份 vendor 源码能在 Cloudberry API 下编译，同时尽量不改变非 Cloudberry 上游路径。

PG16 server headers 已定义 `NumericShort`、`NumericLong`、`NumericData` 及 `NUMERIC_*` 宏。PG-Strom device 公共头若继续使用同名定义会发生冲突，因此相关 device 结构和宏统一改为 `XpuNumeric*` / `XPU_NUMERIC_*`。这只是命名隔离，不改变 numeric 的 on-disk/on-wire 表示。

### 4.3 规划入口和能力过滤

Cloudberry MVP 只在满足以下条件时考虑 GpuScan：

- `optimizer=off`，使用 PostgreSQL planner；
- `pg_strom.enabled=on` 且 `pg_strom.enable_gpuscan=on`；
- GPU Service 已通过 `gpuserv_ready_accept()` 宣告可接收任务；
- RTE 是普通 relation；
- table AM 是 heap；
- 分布策略是普通分布式策略（`GpPolicyIsPartitioned`），排除 coordinator-local 和 replicated 表；
- 不是分区叶子 `RELOPT_OTHER_MEMBER_REL`；
- 至少存在一个 device qual；
- 不存在需要 host 端补充执行的 qual。

最后两条是保守约束。上游 PG-Strom 可以组合 device quals 和 host quals，但 Cloudberry MVP 尚未完整验证这条混合执行链，因此正则表达式等不能下推到 GPU 的条件会回退到原生 Seq Scan，而不是生成部分下推的 GpuScan。

### 4.4 分布式成本和 Path 属性

Cloudberry `RelOptInfo` 中表统计量代表全局分布式表，但一个 QE 上的扫描 Path 应表达该 QE 的工作量。MVP 使用分布策略计算 segment 数，并按 segment 数缩放：

- `ntuples`；
- `scan_nrows`；
- page/disk cost；
- `scan_tuples`；
- `final_nrows`。

startup cost 不缩放，因为每个参与 QE 都要独立完成 GPU setup。

构造 CustomPath 时还补齐 Cloudberry 需要的属性：

- 使用 `cdbpathlocus_from_baserel()` 建立 locus；
- 让 `parallel_workers` 与 locus 一致；
- 初始化 `memory`；
- 设置 `motionHazard=false`、`barrierHazard=false`；
- 声明 `rescannable=true`；
- 设置 `sameslice_relids`。

这些字段决定优化器如何把 GpuScan 放入 QE slice、是否插入 Motion 以及能否用于 rescan。只移植 PostgreSQL 的 CustomPath 而遗漏这些 MPP 属性，会得到成本错误、计划位置错误或计划组合失败。

### 4.5 QD-to-QE CustomScan 重写

Cloudberry 在计划下发前会递归重写计划树中的 varno、表达式和 slice 相关引用。原有 `cdbplan.c` 对 CustomScan 只处理核心 Scan 字段，不会自动进入扩展拥有的列表。

MVP 对以下字段执行递归 mutation：

- `custom_plans`；
- `custom_exprs`；
- `custom_scan_tlist`。

`custom_private` 刻意保持 opaque。它是扩展私有序列化数据，Cloudberry 核心不能把它当通用表达式树解释，否则可能破坏 PG-Strom 自己的数据布局。这个区分是 CustomScan 能从 QD 安全下发到 QE 的关键。

### 4.6 GPU Service 生命周期

GPU Service 是 postmaster background worker，但内部还有 process-private 的 `gpuContext`、worker list 和 pthread task workers。它同时使用 postmaster shared memory 中的 readiness/GUC 状态。

正确的启动顺序是：

1. 将共享 `gpuserv_ready_accept` 设为 false；
2. 初始化 CUDA module、driver 和各 GPU context；
3. 按 `pg_strom.max_async_tasks` 为每个 context 创建 task worker；
4. 检查实际 worker 数达到目标值；
5. memory barrier 后将 readiness 设为 true；
6. 才允许 backend 规划和连接 GpuScan。

这避免了两类竞态：backend 在 worker pool 尚未建立时看到服务 ready，以及 GPU Service 崩溃重启后沿用共享 GUC 状态、却没有重建新进程私有 worker list。

### 4.7 GpuCache 生命周期隔离

虽然 GpuCache 不在 MVP 中注册，PG-Strom 的 service、成本估算和 executor 仍链接着相关调用点。不能仅凭“编译进了同一个 `.so`”就认为 GpuCache 已初始化。

`pgstromGpuCacheIsInitialized()` 只有在以下三项同时存在时才返回 true：

- GpuCache shared state；
- descriptor hash table；
- signature hash table。

规划器、Relation 检查、executor、GPU task dispatch、GpuCacheManager 创建和清理唤醒都先检查这个统一谓词。GpuScan-only 构建因此不会创建 GpuCache manager，也不会访问未初始化 mutex/hash table；将来若恢复 GpuCache 初始化，同一谓词也能自动反映真实状态，不需要散落 Cloudberry 特判。

### 4.8 host/device 存储配置同步

CUDA device code不能直接包含完整 `postgres.h`，上游曾在 device 公共头中写死 PostgreSQL 常量，例如 `BLCKSZ=8192`。当前 Cloudberry 构建的实际 `BLCKSZ=32768`。host 按 32KB page 组织 KDS，而 device 按 8KB stride 解析时，第二个 block 会落到前一个 block 内部，最终表现为：

- `CUDA_ERROR_MISALIGNED_ADDRESS`；
- `CUDA_ERROR_ASSERT`；
- 查询挂起或 GPU Service 异常退出。

修复设计如下：

1. 从目标 `PG_CONFIG` 的安装头提取：
   - `NAMEDATALEN`；
   - `BLCKSZ`；
   - `RELSEG_SIZE`；
   - `PG_PAGE_LAYOUT_VERSION`；
   - `MAXIMUM_ALIGNOF`。
2. 自动生成 `pgstrom_device_config.h`；
3. host 和 device 都使用生成值；
4. 将配置签名加入 CUDA 源码 MD5；
5. runtime fatbin builder 使用完全相同的签名算法。

因此不同 PostgreSQL/Cloudberry 存储布局会生成不同 fatbin 文件名，旧的 8KB fatbin 不会被 32KB Cloudberry 错误复用。实际验收生成并加载的文件为：

```text
pgstrom-gpucode-V012040-32172fbfacbac2689620c930889dce96.fatbin
```

### 4.9 分区表的双层阻断

只禁止分区父 RTE 不够。PostgreSQL planner 会再次为每个叶子调用 path hook；叶子 RTE 的 `inh` 已清除，看起来像普通 heap 表，但 `RelOptInfo.reloptkind` 是 `RELOPT_OTHER_MEMBER_REL`。

因此 Cloudberry 分支还必须在 planner hook 入口拒绝 `RELOPT_OTHER_MEMBER_REL`，阻止 GpuScan 从叶子泄漏进父表的 Append 计划。最终验证中，分区查询生成 Motion + Seq Scan，不包含 GpuScan。

## 5. 当前能力边界

| 维度 | 当前状态 | 说明 |
|---|---|---|
| 集群拓扑 | 支持单机、1 QD + 1 Primary QE | 多 Segment、多主机未验证 |
| 表类型 | 普通分布式 heap | 需要普通 distribution policy |
| Planner | PostgreSQL planner，`optimizer=off` | ORCA 不产生 GpuScan |
| Scan | GpuScan | 已有实际执行与结果签名验证 |
| 条件 | 可完全编译为 device qual 的条件 | host-only 或混合 qual 回退 |
| 投影/类型 | demo 覆盖 bigint、integer、numeric、text | 不代表上游全部类型均已验收 |
| LIMIT | 支持已验收 | LIMIT 下 QE GpuScan 可完成 |
| 参数与 rescan | 基础场景已验收 | prepared、多参数、重复执行、lateral 形状 |
| AO / AOCO | 不支持，安全回退 | 不生成 GpuScan |
| 分区表 | 不支持，安全回退 | 父表与叶子均阻断 |
| replicated / coordinator-local | 不支持 | 规划阶段排除 |
| Arrow/Parquet FDW | MVP 构建禁用 | 使用 stubs 保持链接闭合 |
| GpuJoin/GpuPreAgg/GpuSort | 不注册 | 仍有上游源码，不代表 Cloudberry 可用 |
| GpuCache | 不初始化、不注册 | 生命周期调用点有防护 |
| BRIN GPU acceleration | 不注册 | 不在 MVP 范围 |
| GPU-Direct | 硬禁用 | GUC 尝试启用会被拒绝 |
| SELECT-INTO-Direct | 硬禁用 | GUC checker 拒绝启用 |
| DPU | 不初始化 | 所有 DPU planner path 均在范围外 |
| CPU fallback | 验收配置为 off | GPU 错误应显式失败，避免掩盖错误 |
| 并发资源隔离 | 未实现 | QD/QE 是独立 GPU Service/内存池 |
| 性能 | 未形成结论 | 正确性 demo 不是 benchmark |

## 6. Commit 演进与每次修改的原因/原理

### 6.1 `832046c0b3f` — 导入 PG-Strom v6.1 上游快照

**改动**

- 将上游 commit `4d12ef415759dc48cd4c1421565e9c694b7bd3f9` 的完整源码导入 `gpcontrib/pg_strom`；
- 保留 PostgreSQL License、测试、工具、CUDA/device 源码和历史 deadcode；
- 共导入约 1000 个文件、47 万行。

**原因**

先建立可追溯、未混入 Cloudberry 修改的 vendor 基线，后续所有适配都能通过 commit diff 审计，也便于未来和上游同步。

**原理**

vendor commit 只回答“上游是什么”，不承担“Cloudberry 是否可用”。Cloudberry 适配被放在后续独立 commit 中，避免把来源代码和本地修改混在一起。

### 6.2 `bb90b28e2b5` — 建立单 Primary GpuScan MVP

这是主体移植提交，涉及 25 个文件。

**主要改动及原因**

1. **缩小初始化范围**
   - Cloudberry 只初始化 GPU device、GPU Service 和 GpuScan；
   - 不初始化 GpuJoin、GpuPreAgg、GpuCache、SELECT-INTO、BRIN、Arrow 和 DPU planner hooks；
   - GPU-Direct、SELECT-INTO-Direct 的 GUC 默认关闭且拒绝开启。

   原因是这些上游能力依赖尚未适配的 planner、storage、shared-memory 或分布式语义。显式不注册比让它们偶然进入计划更安全。

2. **构建隔离**
   - 增加 `PGSTROM_WITH_ARROW=0/1`；
   - `0` 时使用 `arrow_stubs.c`；
   - generated headers 成为所有 object 的真实 order-only dependency，保证并行构建安全；
   - 固定上游/Cloudberry MVP githash 标识。

3. **Cloudberry API 兼容**
   - 适配 planner、path、selectivity、aggregate、executor、visibility 和 instrumentation API；
   - 对与 PG16 headers 冲突的 numeric 结构/宏加 `Xpu` 前缀；
   - 修正 `pgstrom_is_gpuscan_plan()` 中错误地用自身未初始化变量强转的问题。

4. **MPP GpuScan Path**
   - 全局统计按 segment 数换算为每 QE 成本和行数；
   - 初始化 locus、parallel worker、hazard、rescan、same-slice 等字段；
   - 只接受普通分布式 heap；
   - 禁止 host quals、无 device qual、分区父表和 ORCA 路径。

5. **CustomScan 下发**
   - `cdbplan.c` 递归处理 `custom_plans`、`custom_exprs` 和 `custom_scan_tlist`；
   - 保持 `custom_private` opaque。

6. **文档和验收资产**
   - 新增 `CLOUDBERRY.md`、配置样例、setup/verify SQL、自动 demo 和静态检查；
   - demo 同时验证正向 GpuScan、CPU/GPU 签名和负向回退边界。

**实现原理**

该提交把“单机 PostgreSQL extension”重新放入 Cloudberry 的 planner/QD-QE execution contract 中：CustomPath 必须携带 MPP locus，CustomScan 私有表达式必须经过计划重写，executor 最终必须在 QE slice 连接 QE 的 GPU Service。功能裁剪则保证未完成的上游模块不会干扰这条最小链路。

### 6.3 `796a24d7f93` — 第一阶段 GpuCache manager 生命周期修复

**故障背景**

GpuScan-only MVP 没有调用 `pgstrom_init_gpu_cache()`，但上游 GPU Service worker 管理仍无条件创建 GpuCacheManager，并在清理时唤醒它。GpuCache 的共享 mutex/hash table 没有初始化，manager 最终在 `gpucacheManagerEventLoop()` 的 `pthread_mutex_lock()` 发生 SIGSEGV。QD/QE 的 GPU Service 周期性崩溃，postmaster 随后终止其他进程并 reinitialize。

**改动**

- 增加 Cloudberry 下恒为 false 的 `gpuservGpuCacheEnabled()`；
- 不创建 GpuCacheManager worker；
- GpuCache task 到达时返回明确错误；
- cleanup 不再唤醒不存在的 manager；
- worker 计数逻辑把“不需要 GpuCache manager”视为已满足；
- 静态测试检查这些生命周期 guard。

**原理**

后台 worker 的生命周期必须和 `_PG_init()` 真正初始化的子系统一致。不能因为函数链接在同一个动态库中，就访问该子系统的共享同步对象。

### 6.4 `bc02da5ae81` — 将 GpuCache 防护推广为统一初始化谓词

**为什么需要第二轮修复**

第一轮使用 `#ifdef GP_VERSION_NUM` 固定判断，能止住当前崩溃，但它把“Cloudberry”错误等同于“GpuCache 永远不可用”，且遗漏 planner 成本估算、Relation 检查和 executor 等其他调用点。更可靠的判断应该基于运行时真实初始化状态。

**改动**

- 新增公开函数 `pgstromGpuCacheIsInitialized()`；
- 只有 shared head、descriptor htab、signature htab 全部存在才返回 true；
- `baseRelHasGpuCache()` 自身在 GUC 关闭或未初始化时返回 `-1`；
- GpuScan 成本估算、`RelationHasGpuCache()`、GpuCache executor init 均增加保护；
- GPU Service task dispatch、manager 创建、worker 调整和 cleanup 全部改用统一谓词；
- 删除第一轮 Cloudberry 专用 helper，更新静态测试。

**原理**

用“能力是否完整初始化”代替“当前编译平台是什么”。该设计同时解决安全性、可维护性和未来扩展性：即使以后 Cloudberry 开放 GpuCache，只要完整调用初始化流程，统一谓词就能自然变为 true。

### 6.5 `1ffd045c5b0` — GPU Service 重启时重建 task worker pool

**故障背景**

处理一次 CUDA 错误后 GPU Service 可以退出并被 postmaster 重启。共享内存里的 `max_async_tasks` 和更新时间仍然存在，但新进程的 `gpuContext`、worker list 和 pthread workers 全部是空的。上游延迟 GUC 调整逻辑只在检测到新更新时间时工作，因此重启后的服务可能显示进程存在，却没有 task worker。backend 连接建立后一直等待 XPU command，查询挂在 Extension wait event，GPU 利用率为 0。

**改动**

- `__gpuContextAdjustWorkersOne()` 返回实际 task worker 数；
- 新增 `__gpuContextStartWorkers()`，每次 GPU Service 进程启动都无条件按当前 `pg_strom.max_async_tasks` 建 worker；
- worker 不足时启动失败并报错；
- 服务启动先清 readiness，worker 建好后才重新置 true；
- 保留运行期间 GUC 变化的延迟调整逻辑；
- 静态测试还检查“创建 worker”源码位置早于“宣告 ready”。

**原理**

区分 postmaster shared state 和 background-worker process-private state。共享配置可跨 worker 重启保留，pthread worker pool 不可以，因此每个新进程都必须从共享配置重建自己的私有运行态。

### 6.6 `a0733d66f27` — host/device PostgreSQL 存储配置同步

**故障背景**

Cloudberry 使用 32KB `BLCKSZ`，device code 仍硬编码 8KB。纯整数、无 LIMIT 查询仍出现 CUDA assert，证明问题不是 numeric 或 LIMIT，而是底层 page/KDS 解析。错误 CUDA context 又可能导致 worker 退出和查询挂起。

**改动**

- 从目标 `pg_config` headers 提取五个存储/ABI 常量；
- 构建时生成并安装 `pgstrom_device_config.h`；
- `xpu_common.h` 不再硬编码这些常量；
- generated header 成为 host/device 编译依赖；
- CUDA build hash 前置统一配置字符串；
- runtime fatbin filename 计算使用同一字符串和同一文件集合；
- 生成文件加入 `.gitignore`；
- 静态测试禁止重新出现 `BLCKSZ 8192`。

**原理**

host 构造数据结构和 device 解析数据结构必须共享同一 ABI。把配置同时纳入源码生成和缓存 key，既保证新编译正确，也防止内容正确但运行时误用旧 fatbin。

### 6.7 `bdf71dbac91` — 阻断分区叶子 GpuScan 泄漏

**故障背景**

host/device 修复后完整 demo 的正向部分全部通过，但负向测试发现分区查询仍出现 GpuScan。父分区路径虽然已被 `#ifndef GP_VERSION_NUM` 禁止，planner 对叶子再次调用 hook 时却走普通 relation 分支。

**改动**

- Cloudberry planner hook 遇到 `baserel->reloptkind == RELOPT_OTHER_MEMBER_REL` 立即返回；
- 静态测试固定这个 guard。

**原理**

分区规划是父表和叶子两阶段行为。MVP 边界必须在两层都实施，而不能只依赖 `rte->inh`。修复后分区叶子只能保留 Cloudberry 原生路径。

## 7. 验收结果如何解读

最终自动 demo 输出中最重要的证据是：

```text
Custom Scan (GpuScan) on public.pgstrom_mvp_heap
Scan-Engine: VFS with GPU0
```

并且它位于：

```text
Gather Motion 1:1 (slice1; segments: 1)
```

这说明 GpuScan 真正在单 Primary QE slice 执行。

CPU/GPU 稳定签名为：

```text
107000|109637978000|79879780.00|43384fb5927e97c4f616dd5846cc13b1
```

最终 runner 输出：

```text
GpuScan plan found and CPU/GPU signatures match
The verbose plan shows GpuScan in a single-primary QE slice.
```

并返回 `demo exit code=0`。同时分区查询最终为：

```text
Seq Scan on public.pgstrom_mvp_partitioned_p1
```

日志显示 QD、QE 均加载配置同步后的 fatbin，并各自打印：

```text
GPU0 workers - 16 startup, 0 terminate
```

这些证据足以支持“功能可用的单 Primary MVP”结论，但不能直接支持“性能优于 CPU”。验收中无 LIMIT 全量查询约 30 秒，而 LIMIT 查询约 0.4 秒；它们受 JIT/fatbin、数据传输、缓存、VFS、数据规模和单机资源共享影响，需要独立 benchmark 才能评价。

## 8. 尚未自动覆盖或需要进一步工程化的事项

1. **多 Segment / 多主机**：需要验证多个 QE、多个 GPU、Motion、数据倾斜及失败传播。
2. **并发隔离**：QD/QE 共享一块 GPU 时，两个服务的内存池比例是独立上限，不是全局协调器。
3. **长稳与故障注入**：需要自动化 GPU Service kill/restart、CUDA fatal error、query cancel、postmaster recovery 和重复恢复测试。
4. **完整类型矩阵**：当前 demo 只证明所覆盖类型/表达式，不等价于上游全部 device type/function 已适配 Cloudberry。
5. **性能工程**：需要区分首次 fatbin/JIT、冷/热缓存、CPU baseline、传输成本和选择率。
6. **ORCA**：若要支持，需要新的 ORCA physical operator/integration，而不是简单打开现有 hook。
7. **AO/AOCO/分区**：需要针对 Cloudberry storage AM 和 partition execution 单独设计，不能移除 guard 后直接宣称支持。
8. **高级 PG-Strom 功能**：GpuJoin、GpuPreAgg、GpuSort、GpuCache、GPU-Direct、Arrow/DPU 都应逐项恢复初始化、规划、MPP 成本和故障测试。
9. **可观测性**：建议增加 service generation、worker 数、fatbin config signature、设备错误计数和 backend/service request id。
10. **CI**：静态测试已存在，但 GPU demo、重启恢复和结果签名仍需要 GPU runner 才能持续回归。

## 9. 推荐的版本定位

对外描述建议使用：

> Cloudberry PG-Strom v6.1 single-primary GpuScan MVP：支持 PostgreSQL planner 下普通分布式 heap 表的单 QE GpuScan，具备 CPU/GPU 结果一致性与安全回退验收；不包含多 Segment、并发隔离、ORCA、AO/AOCO、分区表和其他 PG-Strom 加速算子，尚非生产就绪版本。

这个定位既反映了已经完成的端到端能力，也保留了对未验证范围的工程边界。

## 10. 相关文件

- `gpcontrib/pg_strom/CLOUDBERRY.md`：简要构建与支持范围；
- `gpcontrib/pg_strom/cloudberry/demo/README.md`：单 Primary demo 操作说明；
- `gpcontrib/pg_strom/cloudberry/demo/run_demo.sh`：自动验收入口；
- `gpcontrib/pg_strom/cloudberry/demo/setup.sql`：测试数据与表类型；
- `gpcontrib/pg_strom/cloudberry/demo/verify.sql`：LIMIT、签名、参数与 rescan 测试；
- `gpcontrib/pg_strom/cloudberry/test_static_mvp.sh`：设计边界静态检查；
- `gpcontrib/pg_strom/src/gpu_scan.c`：GpuScan 规划与执行注册；
- `gpcontrib/pg_strom/src/gpu_service.c`：GPU Service、worker、fatbin 和任务执行；
- `gpcontrib/pg_strom/src/gpu_cache.c`：GpuCache 初始化状态保护；
- `gpcontrib/pg_strom/src/Makefile.cuda`：device 配置提取与 fatbin hash；
- `src/backend/cdb/cdbplan.c`：QD-to-QE CustomScan 计划重写。
