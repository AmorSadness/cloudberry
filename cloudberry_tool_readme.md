# Apache Cloudberry 交互式安装与集群运维工具

`cloudberry_tool.sh` 是面向 Apache CloudberryDB 的交互式安装与基础运维工具。
它以官方 `gp*` 工具为执行基础，提供 Demo、快速集群、自定义集群安装，以及集群启停、
状态查看和安全卸载功能。

统一入口：

```bash
./cloudberry_tool.sh
```

## 当前范围

首版 MVP 支持：

- Demo 单机安装。
- 快速集群安装。
- 自定义集群安装。
- Primary Segment 和 Mirror Segment。
- 自定义模式下的可选 Standby Coordinator。
- 自动生成 Cloudberry 初始化配置。
- 支持每台主机独立 SSH 端口和可选 ProxyJump，并将相同 SSH Alias 传递给官方 gp 工具。
- 使用 `gpinitsystem -O` 生成官方拓扑，并使用 `gpinitsystem -I` 初始化。
- 启动、停止、简洁状态和详细状态。
- 删除集群数据，以及独立可选的 binary 删除。
- 严格的 `--dry-run` 模式。

当前不支持：

- 每台 Segment Host 不同数量的 Primary Segment。
- 手工指定每个 content 的 Primary/Mirror 物理位置。
- 在线扩容、rebalance、复杂恢复和滚动升级。
- Cloudberry 内核或跨大版本升级。

## 依赖

### 操作系统

- Linux。
- Bash 4.2 或更高版本。

### 基础命令

所有参与主机需要具备常用系统工具。脚本会检查：

```text
bash
ssh
scp
ssh-keyscan
rsync
tar
awk
sed
grep
hostname
ip
df
getconf
sort
find
dirname
install
```

### Cloudberry 工具

Coordinator 上的 `${CBDB_HOME}/bin` 应包含：

```text
postgres
gpinitsystem
gpstart
gpstop
gpstate
gpssh
gpssh-exkeys
gpdeletesystem
createdb
```

`gpscp` 是可选工具。如 Cloudberry binary 仅存在于 Coordinator，安装过程中可以选择
使用 tar 打包，并优先通过 `gpscp` 分发；当前安装不提供 `gpscp` 时自动回退到 `scp`。
分发保留隐藏文件、权限和符号链接。

### 用户和 SSH

- 数据库初始化和运维必须由同一个非 root 用户执行，默认是 `gpadmin`。
- `gpadmin` 必须存在于所有参与主机。
- 每台主机可以使用独立 SSH 端口，并可配置一个或多个逗号分隔的 ProxyJump。
- 录入的 IPv4 是 SSH `HostName` endpoint；多个 NAT/端口映射节点可共用 IP，但
  `IP:port` 组合必须唯一。
- `gpadmin` 需要能够无密码 SSH 登录所有主机。
- 可以使用脚本引导调用 `gpssh-exkeys` 建立 SSH 信任。
- root 只能执行菜单中的环境准备，不会执行 Cloudberry 初始化和生命周期命令。

MVP 不保存系统密码、数据库密码或 SSH 私钥。

工具为每个主机生成统一的 SSH Host Alias 配置：

```text
conf/ssh_config
conf/ssh-bin/ssh
conf/ssh-bin/scp
conf/ssh-bin/ssh-keyscan
```

`install.conf` 配置版本升级为 2，主机记录增加可选 ProxyJump 字段；版本 1 的四字段主机
记录仍可读取，并会在下次保存时升级。

工具自身的远程检查、binary 分发、`gpssh-exkeys`、`gpssh`、`gpscp`、
`gpinitsystem` 及工具菜单中的生命周期命令都会通过这些文件使用相同的
`HostName`、`Port`、`User` 和 `ProxyJump`。生成配置最后会包含用户自己的
`~/.ssh/config`，因此仍可从中取得 IdentityFile 等通用选项，但工具录入的主机端点优先。

当目标需要 ProxyJump 时，应事先配置可用的密钥认证。`ssh-keyscan` 无法通过
ProxyJump 建立扫描链路，因此工具不会尝试使用 `gpssh-exkeys` 为这类目标从零引导密钥，
而会要求现有的无密码 SSH 先通过检查。直接连接的非 22 端口仍可使用
`gpssh-exkeys`，工具生成的 `ssh-keyscan` 包装器会使用对应的 IP 和端口。

## 安装方式

为脚本添加执行权限：

```bash
chmod +x cloudberry_tool.sh
```

在计划作为 Coordinator 的主机上，以 `gpadmin` 用户运行：

```bash
source /path/to/cloudberry-install/cloudberry-env.sh
./cloudberry_tool.sh
```

加载 `cloudberry-env.sh` 后，脚本会优先使用 `$GPHOME` 作为默认安装路径；如果没有设置
`GPHOME`，则尝试从 PATH 中的 `postgres` 推导安装路径，最后才使用当前用户可写的
`$HOME/cloudberry-install`。

主菜单：

```text
1. Demo 单机安装
2. 快速集群安装
3. 自定义集群安装
4. 启动集群
5. 停止集群
6. 查看集群状态
7. 查看集群配置
8. 卸载集群
9. 环境检查
0. 退出
```

正式安装前或集群运行期间，可以选择 `9. 环境检查（安装前/运行中）`。脚本会根据
`install_state` 自动选择检查语义。

## 快速集群安装

选择：

```text
2. 快速集群安装
```

快速模式约定：

- 第一台录入主机作为 Coordinator。
- 其余主机作为 Segment Host。
- 每台 Segment Host 部署相同数量的 Primary Segment。
- 用户可以选择是否启用 Mirror。
- Mirror 默认使用官方 `group` 模式。
- 只有一台 Segment Host 时，脚本会关闭 Mirror，避免形成伪高可用拓扑。

示例：4 台主机、每台 Segment Host 两个 Primary：

```text
mdw   -> Coordinator
sdw1  -> 2 Primary + Mirror
sdw2  -> 2 Primary + Mirror
sdw3  -> 2 Primary + Mirror
```

最终 content ID、端口和 Mirror 映射由 `gpinitsystem -O` 生成，脚本不会自行猜测。

## 自定义集群安装

选择：

```text
3. 自定义集群安装
```

自定义模式允许配置：

- Coordinator Host。
- Segment Hosts。
- 每台 Segment Host 的 Primary 数量。
- Coordinator、Primary 和 Mirror 端口。
- Coordinator、Primary 和 Mirror 数据目录。
- Mirror 是否启用。
- 官方 `group` 或 `spread` Mirror 模式。
- 可选 Standby Coordinator 和其数据目录。

`spread` 要求 Segment 主机数严格大于每台主机的 Primary 数量。例如两台 Segment
主机、每台两个 Primary 时只能选择 `group`；如果要验证 `spread`，应将 Primary/host
设为 `1`，或增加至少一台 Segment 主机。脚本会在交互阶段检查该条件并重新提示，避免
进入 `gpinitsystem -O` 后才失败。

MVP 不允许 Coordinator 与 Segment 混部，也不允许 Standby Coordinator 与 Segment 混部。
初始化必须从配置的 Coordinator 主机执行。

当前 Cloudberry 版本在默认内部 FTS 配置下，`gpinitsystem` 内部初始化 Standby 时可能向
`gpinitstandby` 传入没有值的 `-f` 参数，同时仍以核心集群初始化成功的状态退出。为避免这种
假成功，工具先运行 `gpinitsystem -I` 初始化核心集群，再显式运行 `gpinitstandby -a -s ...
-P ... -S ...`，并校验 Standby 元数据、远端 PID 和 `gpstate -f`。

在实际初始化前，脚本将执行：

```text
gpinitsystem -O
        ↓
解析并校验官方拓扑
        ↓
显示 Coordinator、Primary、Mirror 完整映射
        ↓
用户最终确认
        ↓
gpinitsystem -I
```

用户拒绝最终拓扑时，不会执行 `gpinitsystem -I`。

## Demo 安装

选择：

```text
1. Demo 单机安装
```

默认配置：

```text
Coordinator port : 5432
Primary ports    : 6000+
Primary count    : 3
Installation     : $HOME/cloudberry-install
Data root        : $HOME/cloudberry-data/demo
Mirror           : disabled
```

Demo 可以选择启用 Mirror，但 Primary 和 Mirror 位于同一物理主机，只适合功能测试，
不提供主机级高可用。

Demo 仍要求本机 SSH 服务可用，并且 `gpadmin` 能无密码 SSH 登录本机，因为
`gpinitsystem` 使用 SSH 管理实例。

## 环境检查

菜单 `9. 环境检查（安装前/运行中）` 根据配置中的 `install_state` 选择检查方式：

- `installed`：验证配置的端口正在监听、实例目录存在、各主机 binary 版本一致，并通过
  `gpstate -b` 检查运行状态。
- 其他状态或新录入配置：执行安装前检查，要求计划端口空闲且目标实例目录不存在。

因此，运行中的集群不会再因为正常占用 5432、Primary 或 Mirror 端口而被误报为环境检查
失败。

## 安装流程

正常安装的大致阶段：

```text
收集并校验配置
        ↓
生成 hostfile 和 gpinitsystem_config
        ↓
检查当前用户和依赖
        ↓
检查 SSH、主机身份和远端用户
        ↓
检查 CPU、内存、磁盘和端口
        ↓
检查或分发 Cloudberry binary
        ↓
在所有主机准备工具日志目录，并检查、准备数据目录
        ↓
gpinitsystem -O 生成官方拓扑
        ↓
用户确认官方拓扑
        ↓
gpinitsystem -I 初始化并启动集群
        ↓
等待 Primary/Mirror 达到 Up；配置 Mirror 时等待全部同步
        ↓
gpstate 验证；配置 Standby 时再初始化并验证 Standby
        ↓
保存 installed 状态
```

`gpinitsystem` 会把 `-l` 指定的日志目录传递给远端 Segment 管理进程，因此多机安装会在
初始化前确保该目录以相同绝对路径存在于所有配置主机上。任一主机无法创建时，安装会在
调用 `gpinitsystem -O/-I` 前失败，避免出现已经初始化数据但无法启动 Segment 的现场。

`gpinitsystem` 初始化成功后通常已经启动集群，脚本不会无条件重复执行 `gpstart`。由于官方
命令可能在 Mirror 尚未被 FTS 标记为 Up/Synchronized 时返回成功，工具最多等待 180 秒，
轮询 `gp_segment_configuration`：无 Mirror 时要求全部 Primary 为 Up；有 Mirror 时要求所有
Primary/Mirror 均为 Up 且处于同步模式。超时会输出 `gpstate` 诊断并将安装状态保存为
`failed`，不会过早报告 `installed`。

工具调用官方 GP 管理命令时统一传递当前配置的 `COORDINATOR_DATA_DIRECTORY` 和 `PGPORT`。
这既保证 `gpinitstandby` 能连接非 5432 Coordinator，也保证 `gpdeletesystem` 按实际端口读取
拓扑，而不是回退到默认端口 5432。

安装成功后，脚本会生成权限为 `600` 的 `conf/cluster-env.sh`，其中加载 Cloudberry
binary 环境并设置当前集群的 `COORDINATOR_DATA_DIRECTORY`、`PGPORT` 和
`PGDATABASE`。脚本不会修改 `~/.bashrc`；需要在当前终端中执行：

```bash
source /path/to/cloudberry_setup_tool/conf/cluster-env.sh
```

之后可以直接运行 `gpstate -s`、`gpstart` 和 `psql`。成功卸载集群时，该工具管理的
环境文件会被删除，避免继续加载已经失效的集群路径。

展示官方拓扑后的确认用于决定是否真正执行 `gpinitsystem -I`。选择 `N` 会停止安装，
不会初始化数据库；配置状态回退为可重试的 `planned`，已经准备的空目录和拓扑文件会保留，
之后可以重新选择相应安装菜单。

## 启动集群

选择：

```text
4. 启动集群
```

脚本从 `conf/install.conf` 加载环境和 Coordinator 数据目录，内部执行：

```bash
gpstart -a -d COORDINATOR_DATA_DIRECTORY
```

启动操作必须在 Coordinator 主机上由配置的 Cloudberry 用户执行。

## 停止集群

选择：

```text
5. 停止集群
```

支持：

```text
fast       默认；终止连接并回滚活动事务
smart      有活动连接时停止失败
immediate  高风险，仅用于明确的紧急场景
```

内部执行：

```bash
gpstop -a -M MODE -d COORDINATOR_DATA_DIRECTORY
```

选择 `immediate` 时必须完整输入：

```text
IMMEDIATE
```

## 查看状态

选择：

```text
6. 查看集群状态
```

简洁状态使用：

```bash
gpstate -b
```

详细状态组合使用：

```bash
gpstate -s
gpstate -c
gpstate -m
gpstate -e
gpstate -f   # 配置 Standby 时
```

可查看 Coordinator、Primary/Mirror 映射、异常 Segment 和 Standby 状态。

状态检查会先探测官方拓扑中的 Coordinator 和 Segment 核心实例端口：全部监听时判定为
`RUNNING` 并调用 `gpstate`；全部未监听时判定为正常的 `STOPPED`，不调用需要连接
Coordinator 的 `gpstate`；仅部分端口监听时判定为 `PARTIALLY RUNNING` 并列出监听和停止的
核心实例。Standby 是被动实例，不能用业务端口是否监听来判断存活；配置 Standby 时由
官方 `gpstate -b`/`gpstate -f` 通过远端 PID 和复制状态单独检查。

环境检查使用相同的三态判断。集群正常停止时仍会检查 binary 一致性和全部实例目录，
并以 `Stopped-cluster environment check completed` 成功结束；部分运行则作为异常失败。

## 查看集群配置

选择：

```text
7. 查看集群配置
```

该功能显示：

- 安装模式和当前安装状态。
- Coordinator 和 Segment Host。
- 端口和数据目录。
- Mirror、Standby 和数据库配置。
- 已生成的官方 Primary/Mirror 拓扑。

## 卸载集群

选择：

```text
8. 卸载集群
```

默认只删除数据库数据，不删除 Cloudberry binary。脚本会展示受影响的数据路径，并要求
完整输入：

```text
DELETE
```

数据删除优先调用官方工具：

```bash
gpdeletesystem -d COORDINATOR_DATA_DIRECTORY
```

`gpdeletesystem` 需要先连接 Coordinator 读取 Segment 拓扑。如果集群已经停止，脚本会
说明原因，并询问是否临时执行 `gpstart`；启动成功后再继续官方删除流程。若启动失败或
用户拒绝启动，不会删除任何数据目录。

官方删除成功后，脚本会依次尝试删除已经为空的 `coordinator/`、`primary/`、`mirror/`
和 `standby/` 父目录。最后，仅当配置的数据根目录（例如
`/home/mkm/cloudberry-data/demo`）完全为空时才删除该目录。这里使用非递归的 `rmdir`；目录中
存在任何未知文件或子目录时都会保留并记录警告。

如果 `gpdeletesystem` 失败，脚本不会自动递归删除数据目录，而是保留现场和日志供排查。

删除 binary 是后续独立选项，默认关闭。如明确选择删除，还需要输入：

```text
DELETE BINARY
```

确认短语不匹配时，脚本会明确说明 binary 删除已跳过并显示保留路径。若集群数据已成功
删除且配置状态为 `uninstalled`，可以再次选择菜单 8，直接重试 binary 删除，无需重复
执行 `gpdeletesystem`。卸载流程结束时会输出最终完成信息。

脚本不使用 `rm -rf`，并拒绝删除 `/`、HOME、脚本目录等受保护路径。

## 配置文件

配置文件集中位于脚本目录下的 `conf/`：

```text
conf/
├── install.conf
├── hostfile
├── hostfile_gpinitsystem
├── gpinitsystem_config
├── gpinitsystem_input
└── cluster-env.sh
```

文件说明：

- `install.conf`：安装参数和当前状态，供启动、停止、状态和卸载使用。
- `hostfile`：所有参与主机，用于 SSH 信任和批量操作。
- `hostfile_gpinitsystem`：Segment Host 列表。
- `gpinitsystem_config`：传递给 `gpinitsystem -c` 的经典初始化配置。
- `gpinitsystem_input`：由 `gpinitsystem -O` 生成，包含官方解析后的完整拓扑。
- `cluster-env.sh`：安装成功后生成的集群环境入口，供用户显式 `source`；卸载后删除。

`install.conf` 使用固定白名单解析，不会被 Shell `source`。配置中不保存密码或私钥。

安装状态可能为：

```text
planned
ready
installed
failed
uninstalled
```

检测到 `installed`、`ready` 或 `failed` 的现场时，脚本不会静默覆盖已有数据库目录。

## 日志目录

工具日志位于：

```text
logs/cloudberry_tool.log
```

示例：

```text
2026-08-17 10:22:31 [INFO] Checking SSH connectivity: sdw1
2026-08-17 10:22:32 [OK] SSH and host identity verified: sdw1
2026-08-17 10:23:18 [ERROR] gpinitsystem failed with exit code 1
```

安装阶段的 `gpinitsystem` 日志目录也会指向脚本的 `logs/`。其他 gp 工具仍可能按照
其官方默认值写入 `~/gpAdminLogs`。初始化失败时，配置、官方拓扑文件和日志会保留，
不会自动清理数据现场。

远程 Bash 检查在终端中显示可读摘要，例如
`Remote command [sdw1]: bash -c <remote script> -- 6000`；完整的安全转义命令写入日志的
`[DETAIL]` 记录，避免多层反斜杠干扰终端输出和检查结果阅读。

## Dry Run

运行：

```bash
./cloudberry_tool.sh --dry-run
```

dry-run 会：

- 执行交互式配置录入和本地输入校验。
- 生成 `install.conf`、hostfile 和 `gpinitsystem_config`。
- 输出意向拓扑。
- 打印正常模式准备执行的 `gpinitsystem -O` 和 `gpinitsystem -I` 命令。

dry-run 不会：

- 发起 SSH 或调用 `gpssh`、`gpscp`、`gpssh-exkeys`。
- 修改远端主机。
- 创建数据库数据目录。
- 分发 Cloudberry binary。
- 执行 `gpinitsystem -O` 或 `gpinitsystem -I`。
- 启动、停止或删除集群。
- 删除数据或 binary 目录。

当前版本的 `gpinitsystem -O` 在输出拓扑前会执行 SSH、端口和远端目录可写性检查，
其中包含临时文件操作。因此严格 dry-run 不调用 `-O`，只显示“意向拓扑”；正式安装
执行 `-O` 后才显示最终官方 content ID 和 Mirror 映射。

## 帮助

查看命令行帮助：

```bash
./cloudberry_tool.sh --help
```

检查 Shell 语法：

```bash
bash -n cloudberry_tool.sh
```
