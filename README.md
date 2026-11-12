# WilsonExpedition / auto_starve

饥荒联机版客户端自动生存 Mod，以及与其配套的独立双分片测试、死亡取证和离线回归工具。当前源码版本为 **0.1.6**；三次死亡驱动优化已完成，70 个实际游戏日和完整四季的目标仍待验收。

## 目录

| 路径 | 用途 |
| --- | --- |
| `mods/WilsonExpedition` | 自动选威尔逊、出生、观察、决策、移动、采集、制作和生存调度 |
| `mods/WilsonExpeditionDiagnostics` | 服务端身份、存活时长、伤害/动作/死亡回执和原版暂停确认 |
| `development-support/nbot-relay` | 独立世界控制器、双端死亡采集、可选只读中继工具 |
| `.pi/extensions/wilson-iteration.js` | 可选的 Pi 死亡/控制器故障通知扩展 |
| `.pi/runtime-recovery` | 已保留的离线回归，直接执行本机原版 Lua 方法作校验 |
| `handoff/iterations.json` | 脱敏后的三轮证据结论、优化和验证范围 |
| `mods/WilsonExpedition/OPTIMIZATIONS.md` | 随 Mod 安装的优化历史、验证结果和后续核查项 |
| `AGENTS.md` | 接手 AI 的状态、职责边界、技术约束和后续工作 |

## 环境

- Windows x64；已安装并能正常启动的 Steam 版饥荒联机版，包含 `bin64` 下的客户端和专服程序。
- Python 3.11 或更新版本、PowerShell 7。源码环境使用 Python 3.14.2、`luaparser 4.2.0`、`lupa 2.8` 验证。
- Node.js 24 或更新版本用于通知扩展的离线检查。纯 Mod 和离线采集工具可以独立使用；启动本项目自动取证控制器需要支持该扩展 API 的 Pi，启动前会检查当前项目的通知心跳。
- 原版脚本仅用于离线回归，由接手者从自己的游戏安装中取得；本仓库只分发项目源码。

## Fork 后部署

以下命令在仓库根目录、PowerShell 7 中运行。将 `<DST_INSTALL_DIR>` 替换为本机游戏目录。

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python deploy.py configure --game-dir "<DST_INSTALL_DIR>"
python deploy.py check
python deploy.py install
python development-support/nbot-relay/iteration.py prepare
```

`configure` 写入被 Git 忽略的 `deployment.local.json`。默认专属测试存储位于仓库的 `.local/dst`，也可通过 `--storage-root` 指定一个专用目录。`deployment.example.json` 展示完整字段。安装和准备步骤不启动游戏。

`install` 从仓库安装两个 Mod，并同步 Mod 目录内的 Markdown 优化记录。遇到同名的其他部署或已安装目录含额外 Lua 文件时会停止；明确需要替换时使用 `python deploy.py install --replace-existing`，原目录会完整移到 `.local/deployment-backups` 保留，再安装当前 checkout。每次修改仓库中的 Mod 后，都需要再次运行 `install`，控制器会核对已安装源码与当前 checkout 一致。

`prepare` 通过当前 Steam 注册表确定测试账号，自动生成隔离客户端、管理员列表、无尽世界和原版四季配置。所有本机身份与路径保存在被忽略的 `private`、`.local` 目录中；应保留这些目录为本机运行资料。

### 原版脚本和完整离线回归

若游戏已经有 `data/databundles/scripts/components/playercontroller.lua`，可以直接运行测试。否则从自己的原版脚本包解压到专用本地目录，再配置包含 `components`、`prefabs` 等子目录的路径：

```powershell
python deploy.py configure --game-dir "<DST_INSTALL_DIR>" --scripts-dir "<EXTRACTED_NATIVE_SCRIPTS_DIR>"
python deploy.py test
```

`test` 执行原有照明、原版装备、连续工作、连续移动、空地标、威胁/撤退、高脚鸟、死亡归档、双分片暂停、暂停重建和 Windows 状态替换回归，再验证部署与通知扩展。整个命令仅做离线检查。`check` 只需要 Python 依赖，可以在没有游戏安装时检查源码语法。

### 通知与启动一轮实测

在 **本仓库根目录**打开 Pi。首次安装扩展或更新扩展后，在全部会话空闲时执行 `/reload`。然后从已激活的虚拟环境运行：

```powershell
python development-support/nbot-relay/iteration.py preflight
python development-support/nbot-relay/iteration.py run --capture-only
```

`preflight` 的 `agentExtension.ready` 必须为 `true`。控制器会创建专属地表、洞穴和一个可见窗口客户端；Mod 自动选角、出生和生存。核心测试流程使用本地日志与持久文件，独立于可选 Go 中继。

`--capture-only` 在死亡后完成双端归档、等待两个分片的原版暂停回执，然后保留画面和世界暂停，等待用户指令。结束控制器时在另一个终端运行：

```powershell
python development-support/nbot-relay/iteration.py status
python development-support/nbot-relay/iteration.py stop
```

控制器只关闭它创建并持有的进程。若发现外部 DST 进程或测试端口已被占用，会停止启动，交由使用者确认后处理。

### 获准的修复与下一轮

只有用户明确授权死亡驱动迭代时，才省略 `--capture-only` 启动。在死亡后核验队列和归档完整性，完成源码修复、更新 `mods/WilsonExpedition/OPTIMIZATIONS.md`，再安装并检查后执行：

```powershell
python deploy.py install
python deploy.py test
python development-support/nbot-relay/iteration.py approve <DEATH_JOB_ID> --summary "具体故障、修改及检查结果"
```

`approve` 会让**正在运行并持有该世界的项目控制器**重建测试世界。须先保存故障世界，核对剩余轮数和当前授权；审批后由两个新分片会话和新 build 的客户端启动事件确认下一轮。历史三轮批次已经结束，接手者应获得新的实测授权后再开始。

运行状态在 `development-support/nbot-relay/private/iteration-state.json`，死亡队列在 `private/iteration-queue`，证据在 `captures`。状态为 `blocked`、锁文件遗留或进程异常时，应先核对日志和 PID；现有进程不得被另一个控制器静默接管。

## 可选中继

`server` 和 `nbot_relay` 保留了开发辅助中继源码，默认不安装、不启动；Go 构建要求 1.23 或更新版本，本次交接未验证 Go 编译。`relay_tool.py` 的调用范围固定为本机只读状态查询和日志采集。需要启用时自行生成本地 token，使用 `127.0.0.1`，将配置写入被忽略的 `private`，并保持客户端伴生 Mod 默认关闭直至明确启用。详细职责边界见 `AGENTS.md`。

## 当前验证边界

0.1.6 已通过语法和相关离线回归，高脚鸟修复尚未进行下一轮游戏验证。此前轮次验证了自动选角、生存启动、火把装备、双端死亡取证和双分片原版暂停；长期四季生存、持续工作/移动的实际画面表现及失焦运行仍需后续实测。两首领路线继续暂停。交接包提供新的部署能力，原成员保留的故障存档与原始日志通过其本机资料管理。
