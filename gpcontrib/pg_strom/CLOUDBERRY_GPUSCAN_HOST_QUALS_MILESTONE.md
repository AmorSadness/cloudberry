# Cloudberry GpuScan 混合 Host/Device Quals 里程碑总结

> 文档基线：Cloudberry `main` 分支，HEAD
> `76f99fafc06c1efcddb4c0b7b1f3aa870176ab54`  
> 前置基线：`CLOUDBERRY_GPUSCAN_OBSERVABILITY_RECOVERY_MILESTONE.md`  
> 设计基线：`CLOUDBERRY_GPUSCAN_HOST_QUALS_DESIGN.md`  
> GPU 验收日期：2026-08-05

## 1. 结论

默认关闭的 Cloudberry GpuScan 混合 host/device quals 实验能力已经在真实 GPU、
单机双 Primary 环境完成端到端验收。

本次验收证明：

- `pg_strom.cloudberry_enable_host_quals` 存在且默认值为 `off`；
- GUC 开启后，至少含一个 device qual 的查询可以生成 QE GpuScan，并在 GPU
  过滤后由 QE backend 执行 regexp 等 host quals；
- verbose plan 同时显示 `GPU Scan Quals`、标准 `Filter` 和
  `Rows Removed by Filter`；
- 均匀、单 Segment 倾斜和仅一个非空 QE 的小表三种数据形状结果正确；
- 三种 mixed-quals 查询的 CPU/GPU 签名分别连续三轮完全一致；
- NULL、prepared statement、参数变化、LIMIT 和 lateral/rescan 形状通过；
- 纯 host-only、ORCA、AO、AOCO 和分区查询继续保持原生计划；
- query cancel、SIGHUP 和 SIGKILL/Segment crash recovery 均连续三轮通过，
  没有部分结果，队列和签名均恢复。

因此，设计文档中的“真实双 Primary GPU 验收待完成”出口已经完成。该能力仍然
默认关闭并定位为实验特性；本里程碑不证明性能收益、多主机、Mirror/FTS、并发
资源隔离、CUDA fatal 或其他 PG-Strom 算子，也不等于生产就绪。

## 2. 验收拓扑

```text
1 Coordinator（QD）
2 up preferred Primary Segment（content 0/1，端口 7002/7003）
0 Mirror
0 Coordinator Standby
1 台主机，各 postmaster GPU Service 共享同一块 GPU
```

验收数据库为 `pgstrom_mvp`。runner 动态确认两个 preferred Primary 均为 up，
GPU Service status 返回 2 个 Primary 和 1 个 Coordinator，三者均 ready 且实际
worker 数等于配置值。

## 3. 计划放置与条件拆分

均匀表 mixed 查询的关键计划形状为：

```text
Gather Motion 2:1  (slice1; segments: 2)
  -> Custom Scan (GpuScan) on pgstrom_mvp_heap
       Filter: payload ~ '^[0-7]'
       Rows Removed by Filter: 26885
       GPU Scan Quals: grp BETWEEN 101 AND 207
                       AND amount >= 500.00
       Scan-Engine: VFS with GPU0
```

这证明 numeric/integer 条件在两个 QE 的 GPU Service 执行，regexp 条件保留为
每个 QE 的标准 `plan.qual` 并由 `ExecQual()` 执行，而不是在 QD 过滤或整条查询
回退 Seq Scan。

skew 和 small 计划还验证了：

```text
Filter: payload IS NULL OR payload ~ '^[0-7]'
```

其中 skew 表只有 content 1 持有 300000 行，small 表只有 content 1 持有 16 行；
其余 QE 执行合法空扫描。

## 4. CPU/GPU 结果证据

每个 mixed 查询均执行一次 CPU baseline 和三次 GPU 查询，签名如下：

| 数据形状 | CPU/GPU 稳定签名 | 三轮结果 |
|---|---|---|
| uniform | `53447\|54586066298\|39920662.98\|077b7f102f4747130f189ab0446c18f7` | 一致 |
| skew + NULL | `49803\|8113542616\|6422971\|5545\|401fdac0d11b295efbb5b12de4a00233` | 一致 |
| small + 空 QE | `6\|56\|3\|c0121f727d118eae3607ffb328946777` | 一致 |

原 device-only uniform、skew、small 签名也各连续三轮一致，证明新增 GUC 没有
改变默认路径的结果。

`verify.sql` 进一步完成：

- mixed regexp 查询的 `LIMIT 10000`；
- device integer 参数与 host regexp 参数组合的 prepared statement；
- 参数变化和重复执行；
- mixed lateral/rescan 结果；
- bigint、integer、numeric、text 和 NULL 投影。

## 5. 默认关闭与安全回退

GPU host 上执行：

```sql
SHOW pg_strom.cloudberry_enable_host_quals;
```

返回 `off`。runner 显式验证：

- GUC 为 off 时，device + regexp 混合查询不生成 GpuScan；
- GUC 为 on 时，纯 regexp、没有 device qual 的查询仍不生成 GpuScan；
- ORCA、AO、AOCO 和分区查询仍不生成 GpuScan。

因此 P1 没有移除“至少一个 device qual”、普通分布式非分区 heap、PostgreSQL
planner 等既有 guard。

## 6. Query cancel

`run_query_cancel.sh` 连续三轮通过：

| 轮次 | submitted | terminal | completed | failed | cancelled |
|---|---:|---:|---:|---:|---:|
| 1 | 6 | 6 | 6 | 0 | 0 |
| 2 | 12 | 12 | 12 | 0 | 0 |
| 3 | 12 | 12 | 12 | 0 | 0 |

每轮 backend 均收到 SQL cancellation，所有新增 command 都进入终态，所有 QE
queue/active/client gauge 归零，随后 CPU/GPU 签名恢复。

`cancelled_commands=0` 符合计数语义：本次 GPU commands 在 SQL cancel 到达前
已经成功返回并计入 completed；它不表示 backend 没有被取消。

## 7. SIGHUP 恢复

目标为 content 0。三轮均在 Service 不可用窗口得到明确连接错误，分布式查询
失败且没有部分结果。恢复证据为：

| 轮次 | Service PID | generation | worker 日志 | 结果 |
|---|---|---|---|---|
| 1 | `430168 → 435069` | `1 → 2` | `10 → 11` | 签名恢复 |
| 2 | `435069 → 435376` | `2 → 3` | `11 → 12` | 签名恢复 |
| 3 | `435376 → 435675` | `3 → 4` | `12 → 13` | 签名恢复 |

同一个 shared-memory epoch 内 generation 严格递增，新 Service 在完整创建 16
个 worker 后才恢复 ready。

## 8. SIGKILL 与 crash recovery

在可丢弃验收集群中对同一 content 执行三轮 SIGKILL。每轮分布式查询均明确
失败且无部分结果，之后新 PID、完整 worker pool 和签名恢复：

| 轮次 | Service PID | generation | worker 日志 | 结果 |
|---|---|---|---|---|
| 1 | `435675 → 436245` | `4 → 2` | `13 → 14` | epoch reset，签名恢复 |
| 2 | `436245 → 436501` | `2 → 2` | `14 → 15` | epoch reset，签名恢复 |
| 3 | `436501 → 436763` | `2 → 2` | `15 → 16` | epoch reset，签名恢复 |

SIGKILL 触发 Segment crash recovery 并重建 shared memory，因此新旧 generation
属于不同 epoch，数值相等或降低均不表示恢复失败。runner 使用新 PID、ready、
16 个 worker、启动日志和恢复签名作为强故障出口。

## 9. 最终验收状态

| 出口 | 状态 |
|---|---|
| 静态 guards | 通过 |
| 双 Primary device-only GpuScan | 通过 |
| 双 Primary mixed host/device quals | 通过 |
| uniform/skew/small CPU/GPU 三轮签名 | 通过 |
| NULL、prepared、LIMIT、rescan | 通过 |
| 默认关闭与纯 host-only 回退 | 通过 |
| Query cancel 三轮 | 通过 |
| SIGHUP 三轮 | 通过 |
| SIGKILL/crash recovery 三轮 | 通过 |

## 10. 保留边界

- 能力默认关闭，需会话显式设置
  `pg_strom.cloudberry_enable_host_quals=on`；
- 必须至少有一个 device qual；
- 仅支持 PostgreSQL planner 下普通分布式非分区 heap；
- 不支持 ORCA、AO/AOCO、分区、replicated/coordinator-local；
- 不形成性能结论，`enable_seqscan=off` 仅用于暴露合法路径；
- 不覆盖多主机、Mirror/FTS、并发资源隔离、长时间 soak 或 CUDA fatal；
- 不开放 GpuJoin、GpuPreAgg、GpuSort、GpuCache、GPU-Direct、Arrow 或 DPU。

对外建议描述为：

> Cloudberry PG-Strom v6.1 experimental mixed-quals GpuScan milestone：默认关闭，
> 在 PostgreSQL planner 下支持普通分布式 heap 表由 GPU 执行 device quals、
> QE backend 执行剩余 host quals；已在单机 1 QD + 2 Primary 环境完成计划拆分、
> CPU/GPU 三轮签名、NULL/参数/LIMIT/rescan、query cancel、SIGHUP 与
> SIGKILL/crash recovery 验收；不包含性能结论、多主机、Mirror/FTS、并发资源
> 隔离、ORCA、AO/AOCO、分区和其他 GPU 算子，尚非生产就绪版本。
