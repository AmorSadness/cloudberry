# Cloudberry 受限 GpuSort：实现与验收

状态：2026-09-24，源码实现及无 GPU 检查完成，**GPU 验收待完成**。
当前环境无 GPU/CUDA SDK，未执行真实 SQL 排序、设备编译、性能或故障恢复验收。
默认关闭，不改变已验收功能的默认启用范围。

## 第一阶段范围

复用上游 GPU 排序内核，将排序融合到 GpuScan 或受限共置 GpuJoin 的最终结果中。
EXPLAIN 节点仍是 `GpuScan` / `GpuJoin`，通过 `GPU-Sort keys` 识别排序，
不是独立名为 GpuSort 的 Custom Scan。

| 项目 | 本阶段边界 |
| --- | --- |
| 拓扑与 planner | 标准 planner，`optimizer=off`；每个 Service 仅一个可见 GPU；不启用并行 CustomPath |
| 输入 | 普通分布式、非分区 heap；或现有可证明共置的两表 INNER hash GpuJoin |
| 类型 | bool、int2、int4、int8、date、time、timestamp、timestamptz |
| 排序键 | 直接列引用、类型默认 btree opfamily；多列、ASC/DESC、NULLS FIRST/LAST |
| GPU 物化目标 | 上述定长类型的 Var/Const；SQL 上层可保留原生投影 |
| 全局顺序 | QE 内 GPU 排序；Cloudberry 原生 merge Motion 归并 |
| LIMIT | 原生全局 LIMIT/OFFSET/WITH TIES；不下推 GPU Top-K，仍缓存全部输入 |
| 内存 | 有界内存排序，无 spill；估算超限不生成路径，实际超限明确报错 |

float 暂不支持：上游比较实现对 NaN 的关系不能证明符合 PostgreSQL 排序语义。
numeric、text/collation、变长输出、表达式排序键暂不支持。
聚合、窗口、DISTINCT、集合操作、SRF、参数化路径、输入 Motion、host quals、
分区/继承、AO/AOCO、复制表、coordinator-local 输入保留原生排序。
GpuJoin 同时受其[共置限制](CLOUDBERRY_GPUJOIN_COLOCATED_DESIGN.md)约束。

允许无 WHERE 的合格 GpuScan+Sort；该入口不会放开一般无谓词 GpuScan。
如果排序不合格，不将这条私有扫描候选作为无排序路径发布。

## 计划和执行契约

排序路径显式设置 `pathkeys`，只声明当前 QE 内顺序。最终排序仍由 Cloudberry
原生有序 Gather Motion 合并。禁止 planner 改写 CustomPath 投影，避免删掉或替换
已经生成的排序键；阻塞排序的 startup cost 等于 total cost。
只在当前关系覆盖全部基本关系时添加排序，避免在多表查询的单表上误标最终顺序。

`pg_strom.cpu_fallback=off` 是必要条件；CPU fallback 的输出不能绕过完整排序。
该 GUC 在 QD/QE 同步，执行器也检查缓存计划执行时的值。
预备语句每次执行为排序缓冲区产生新的标识，避免误用上次结果。
GpuScan 的排序 EXPLAIN ANALYZE 不再访问不存在的 join inner 统计。
Join+Sort 的 final-buffer 收集仅访问 projection KDS，不把 join inner 缓冲区解释为结果 KDS。

`pg_strom.cloudberry_gpusort_max_buffer_size` 默认 `256MB`，范围 `32MB..4096MB`，
按每次 QE 执行限制仍存活的 projection 分配总量，包含合并时新旧缓冲区同时存在的峰值。
初始 projection 缓冲区为 16MiB。planner 保守估算双份结果加分配余量；
运行时在共享预算预留和 CUDA 分配前再次检查，错误为
`Cloudberry GpuSort exceeds cloudberry_gpusort_max_buffer_size`。
行索引也限制在 bitonic 排序可表示范围内。

此限制不是查询总显存上限：join inner、排序 scratch、内存池另受共享 GPU 预算约束。
没有 spill 或执行中静默 CPU 重试。估算误差、数据倾斜或并发预算不足仍可能导致明确错误。
实际分配量还受分配粒度影响，不能用配置值反推精确可排序行数。

新增 `kern_session_info.gpusort_max_buffer_bytes` 改变主机/设备通信布局。
部署必须完整 clean 重编译主机和设备代码、安装到所有实例并重启 Service/集群，
不能混用旧二进制、设备缓存和新二进制。SQL 扩展版本仍为 6.3，共享预算 ledger v2 不变；
这不代表旧主机/设备二进制兼容。

## 使用示例

```sql
SET optimizer=off;
SET pg_strom.enabled=on;
SET pg_strom.enable_gpuscan=on;
SET pg_strom.enable_gpusort=on;
SET pg_strom.cpu_fallback=off;
SET max_parallel_workers_per_gather=0;
SET pg_strom.cloudberry_gpusort_max_buffer_size='256MB';
-- t 为普通分布式 heap，k/id 为整数。
EXPLAIN (ANALYZE, VERBOSE)
SELECT id,k FROM t ORDER BY k DESC NULLS LAST,id LIMIT 100;
```

正常成本模型可能选择原生排序；启用开关不保证命中 GPU。
合格计划应包含 `GPU-Sort keys`、`Cloudberry GPU-Sort` 和 buffer limit，
上层有带 Merge Key 的 Motion，LIMIT 留在全局归并之后。

## 当前环境验证

从仓库根目录执行：

```sh
bash gpcontrib/pg_strom/cloudberry/test_development.sh
PG_CONFIG=/home/mkm/cloudberry-install/bin/pg_config \
  bash gpcontrib/pg_strom/cloudberry/check_gpujoin_host_syntax.sh
git diff --check
```

包含排序计划验收器的正反例、源码保护条件、实际内存策略头文件的 CPU
边界/溢出/新旧缓冲区峰值测试，以及既有开发检查。
主机语法检查覆盖 planner/executor 等 C 文件，使用临时不透明 CUDA 声明，
**不覆盖完整 gpu_service.c 的 SDK 编译、链接和设备代码，也不是 GPU 正确性证据**。

## GPU 环境验收

先完成完整 SDK/device 构建并部署同一源码。使用一 QD、至少两 Primary、
各 Service 一个可见 GPU 的独立验收集群；本阶段 runner 面向单机共享 GPU。

```sh
PGDATABASE=pgstrom_mvp python3 gpcontrib/pg_strom/cloudberry/demo/run_gpusort_regression.py
# 较大数据集的缓存计划内存上限，以及仅空闲专用集群上执行的 superuser 故障注入：
PGDATABASE=pgstrom_mvp python3 gpcontrib/pg_strom/cloudberry/demo/run_gpusort_regression.py \
  --clients 4 --buffer-limit --fault-injection
# 单独评估正常成本模型；原生路径不计作 GPU 正例通过：
PGDATABASE=pgstrom_mvp python3 gpcontrib/pg_strom/cloudberry/demo/run_gpusort_regression.py --normal-planner
```

默认 runner 调整成本和原生算子开关以暴露候选，属于正确性验收，不是性能测试。
使用独立 schema 并清理；结果默认写到唯一 `/tmp/pgstrom-gpusort-*` 目录。
可通过 `PGSTROM_RESULTS` 指定尚不存在的输出目录。
保存源码 hash/revision/diff、计划、CPU/GPU 原始有序 CSV 和资源状态。

覆盖四种排序/NULL 组合、多键、隐藏排序键、整数边界、日期时间、空输入/单行、
重复行、无谓词扫描、设备过滤、共置 Join+Sort、LIMIT/OFFSET/WITH TIES、
同后端 generic prepared 重复执行和数据变更、并发执行，以及不支持形状的拒绝。
正例必须真正命中 GPU 排序，不允许 CPU Sort 遮蔽错误 pathkeys；
必须存在上层 merge Motion，不允许 GPU 输入内部有 Motion。

CPU/GPU 按原始返回次序逐行比较，**不重新排序后比较集合**。
用唯一 tie-breaker 消除不确定顺序；WITH TIES 测试只输出相同 peer 值。
有重复投影的行仍保留其重数。一般用户查询未指定 tie-breaker 时，不承诺相等键间稳定排序。

`--buffer-limit` 用缓存计划和后续百万行输入触发实际缓冲区上限，要求精确错误、
无部分输出、资源归还及后续查询恢复。`--fault-injection` 验证初始分配预留后的失败回滚。
未选择的检查生成 `.SKIPPED`；`SELECTED_CASES_PASSED` 只代表选中的用例。

以下仍需人工补齐，runner 始终记录 `recovery.SKIPPED`：

1. 在较大排序期间取消、客户端断连，再次执行；确认无部分排序结果及残留预算。
2. Service SIGHUP/SIGKILL、重启和 stale reclaim 后再次执行，并检查所有实例健康。
3. 真实 rescan、merge 替换分配失败、scratch 分配失败的清理及恢复。
4. 共享显存压力下与 GpuScan/GpuJoin/GpuPreAgg 混合并发，检查 FIFO 进展和资源回归基线。
5. 普通成本模型计划与性能，倾斜数据、多 chunk/多缓冲区合并和持续重复执行。

所有证据齐备前保留“实验性、GPU 待验收”状态；既有共享预算验收不自动覆盖新排序生命周期。
