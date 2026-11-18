# Codex 用量透视

原生 Windows 托盘程序，查看本机 Codex 的 token 用量、活动速率、会话与子会话关系，以及周配额估算。提供深色半透明小窗，支持新建、运行、待回答、失败、完成和中断状态的动画。

独立社区项目，与 OpenAI 无隶属关系。界面为中文。支持 **Windows 11 x64**，使用系统自带的 Windows PowerShell 5.1 / WPF，以及随包提供的 Node.js 24.12.0。

PowerShell 策略须允许运行本地脚本。若设备由组织管理且禁止脚本，需由管理员按设备策略处理；程序不会修改执行策略或系统安全设置。

## 安装

### 下载完整 ZIP

下载 `CodexUsageMonitor-2.8.0-win-x64.zip`，完整解压到可写目录，双击 `Start.cmd`。包内已带采集器运行时。`Demo.cmd` 可以查看模拟会话和动效。[最新发行版](https://github.com/headlessj4ger/codex-usage-monitor/releases/latest)

### 通过 npm 安装完整包

已有 Node.js 18+ 和 npm 的 Windows x64 用户，在终端运行：

```powershell
npm install -g https://github.com/headlessj4ger/codex-usage-monitor/releases/download/v2.8.0/codex-usage-monitor-2.8.0.tgz
codex-usage-monitor
```

安装包内含采集器使用的完整 Node.js 运行时，安装时验证 SHA-256。此命令直接从 GitHub Release 安装，无需 npm 账号。当前未发布到 npmjs 注册表。

```powershell
codex-usage-monitor mini       # 打开悬浮小窗
codex-usage-monitor main       # 打开主窗口
codex-usage-monitor tray       # 收起到托盘
codex-usage-monitor demo       # 播放模拟状态与动画
codex-usage-monitor doctor     # 检查运行时与 Codex 数据目录
codex-usage-monitor data-path  # 查看统计数据位置
```

关闭窗口会收起到托盘；从托盘菜单选择“退出程序”才会停止采集。重复启动会打开已有实例。

## 数据发现与保存

启动后自动读取当前 Windows 用户的 `%USERPROFILE%\.codex`。如果设置了 `CODEX_HOME`，则读取指定目录。先在 Codex 中产生会话记录，监控器才能显示用量；无需手动填写 PID。

| 安装方式 | 统计缓存 | 界面设置 |
| --- | --- | --- |
| 完整 ZIP | 程序目录下 `data/usage-v2.sqlite` | 程序目录下 `settings.json` |
| npm | `%LOCALAPPDATA%\CodexUsageMonitor\usage-v2.sqlite` | 同一目录下 `settings.json` |

升级便携版时，先从托盘退出程序，再将新包解压覆盖原目录的程序文件。保留原目录下的 `data/` 和 `settings.json`，即可继续使用已有统计和设置。

可用绝对路径环境变量 `CODEX_MONITOR_DATA` 指定独立的数据目录。npm 升级不会覆盖该目录。升级前从托盘退出程序，再执行新版本的安装命令。卸载前关闭程序内的开机启动，再退出程序，执行 `npm uninstall -g codex-usage-monitor`；个人统计数据保留，按需自行删除。

程序只读 Codex 的本地数据，不读取登录凭据 `auth.json`。运行时采集不上传会话数据；从源码安装且缺少运行时时，安装器仅连接 `nodejs.org` 下载固定版本。

## 统计口径

- 速率为最近 1 分钟已入账输出 token 的均值，输出包含推理 token；柱形每根覆盖 30 秒。Codex 通常在响应结束后写入用量，因此它反映完成响应的吞吐，不是逐字流式速度。
- 每个会话默认只计算自身用量，详情另列子树合计。
- 模型表显示周期用量占比和周期总量占比。程序先按本机计费权重给出暂估，再根据账户配额变化自动校正各模型组合。点击组合可查看估算依据和验证进度。
- 状态变化监听本地文件并每秒补查，及时程度取决于 Codex 何时写出记录。支持已验证的异步问题提醒，客户端权限审批的内存状态尚未接入。
- 完成、失败和中断行保留到本地确认或客户端已读；点击可打开对应 Codex 会话。

完整操作见 [使用说明](docs/user-guide.md)，计算方法见 [统计口径](docs/metrics.md)。

## 开发与验证

源码不提交运行时二进制。克隆后在 Windows x64 上运行：

```powershell
npm install
npm test
npm run test:ui
npm run pack:release
powershell.exe -NoProfile -File scripts/package.ps1
powershell.exe -NoProfile -File scripts/verify-package.ps1
powershell.exe -NoProfile -File scripts/test-npm.ps1
```

`npm install` 会从 Node.js 官方下载固定版本，校验后保存至 `src/runtime/node.exe`。没有第三方 npm 依赖。普通测试使用合成数据；WPF 自检只读本机 Codex 数据，测试缓存和设置写入 `.build/`。

| 目录 | 内容 |
| --- | --- |
| `src/` | WPF 界面、采集器、状态与校准逻辑 |
| `bin/`、`lib/` | npm 命令与运行时安装器 |
| `tests/`、`scripts/` | 测试、打包与校验 |
| `docs/` | 使用说明、架构、视觉与动效规范 |
| `outputs/`、`.build/` | 本机发行包与临时文件，不提交仓库 |

发布流程见 [维护与发布](docs/releasing.md)。

## 许可证

项目采用 [MIT](LICENSE)。随包 Node.js 的许可证见 [LICENSE.node.txt](src/runtime/LICENSE.node.txt)。
