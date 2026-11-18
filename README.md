# Codex 用量透视

原生 Windows 托盘程序，查看本机 Codex 的 token 用量、活动速率、会话与子会话关系，以及周配额估算。提供深色半透明小窗，支持新建、运行、待回答、失败、完成和中断状态的动画。

独立社区项目，与 OpenAI 无隶属关系。界面为中文，支持 **Windows 11 x64**。主程序是 C# WPF 原生 EXE，安装包自带 .NET 桌面运行时和 Node.js 24.12.0。

## 安装

### 下载完整 ZIP

从 [发行版页面](https://github.com/headlessj4ger/codex-usage-monitor/releases) 下载相应版本的 `CodexUsageMonitor-<版本>-win-x64.zip`，完整解压到可写目录，双击 `CodexUsageMonitor.exe`。无需预装 .NET、Node.js 或 npm。`Demo.cmd` 可以查看模拟会话与动效。

### 通过 npm 安装完整包

已有 Node.js 18+ 和 npm 的 Windows x64 用户，在终端运行：

```powershell
npm install -g ./codex-usage-monitor-3.0.0.tgz
codex-usage-monitor
```

在 tgz 下载目录运行命令。此包包含原生 EXE、.NET 桌面运行时和 Node.js 采集器，安装时校验 Node.js SHA-256，无需 npm 账号。若当前发行页只有 2.x，3.x 尚未公开发布。

```powershell
codex-usage-monitor mini       # 打开悬浮小窗
codex-usage-monitor main       # 打开主窗口
codex-usage-monitor tray       # 收起到托盘
codex-usage-monitor demo       # 播放模拟状态与动画
codex-usage-monitor doctor     # 检查运行时与 Codex 数据目录
codex-usage-monitor data-path  # 查看统计数据位置
```

### 从开发分支运行 Start.cmd

下载 `migration/native-wpf` 的源码。在 Windows x64 上安装 Node.js 18+ 后，从仓库根目录运行以下命令。第一条命令会下载并校验采集器需要的 Node.js 运行时。

```powershell
node .\bin\codex-usage-monitor.cjs install-runtime
.\src\Start.cmd -Check
.\src\Start.cmd
```

关闭窗口会收起到托盘；从托盘菜单选择“退出程序”才会停止采集。重复启动会打开已有实例。

## 数据发现与保存

启动后自动读取当前 Windows 用户的 `%USERPROFILE%\.codex`。如果设置了 `CODEX_HOME`，则读取指定目录。先在 Codex 中产生会话记录，监控器才能显示用量；无需手动填写 PID。

| 安装方式 | 统计缓存 | 界面设置 |
| --- | --- | --- |
| 完整 ZIP | 程序目录下 `data/usage-v2.sqlite` | 程序目录下 `settings.json` |
| npm | `%LOCALAPPDATA%\CodexUsageMonitor\usage-v2.sqlite` | 同一目录下 `settings.json` |

可用绝对路径环境变量 `CODEX_MONITOR_DATA` 指定独立的数据目录。npm 升级不会覆盖该目录。升级前从托盘退出程序，再执行新版本的安装命令。卸载前关闭程序内的开机启动，再退出程序，执行 `npm uninstall -g codex-usage-monitor`；个人统计数据保留，按需自行删除。

程序只读 Codex 的本地数据，不读取登录凭据 `auth.json`。运行时采集不上传会话数据；从源码安装且缺少运行时时，安装器仅连接 `nodejs.org` 下载固定版本。

## 统计口径

- 速率为最近 1 分钟已入账输出 token 的均值，输出包含推理 token；柱形每根覆盖 30 秒。Codex 通常在响应结束后写入用量，因此它反映完成响应的吞吐，不是逐字流式速度。
- 每个会话默认只计算自身用量，详情另列子树合计。
- 周配额来自本机日志中的账户快照。模型表先用本机计费权重暂估周期用量占比和周期总量占比，再按模型、思考深度和服务档位用实测区间校正。模型详情展示占比依据及验证进度。
- 状态变化监听本地文件并每秒补查，及时程度取决于 Codex 何时写出记录。支持已验证的异步问题提醒，客户端权限审批的内存状态尚未接入。
- 完成、失败和中断行保留到本地确认或客户端已读；点击可打开对应 Codex 会话。

完整操作见 [使用说明](docs/user-guide.md)，计算方法见 [统计口径](docs/metrics.md)。

## 开发与验证

源码不提交运行时二进制。克隆后在 Windows x64 上运行：

```powershell
npm install
npm test
powershell.exe -NoProfile -File scripts/publish-native.ps1
npm run test:ui
npm run pack:release
powershell.exe -NoProfile -File scripts/package.ps1
powershell.exe -NoProfile -File scripts/verify-package.ps1
powershell.exe -NoProfile -File scripts/test-npm.ps1
```

`npm install` 从 Node.js 官方下载并校验固定版本。源码构建需要 .NET 10 SDK；运行完整包不需要 SDK。普通测试、WPF 自检和启动检查使用合成数据，诊断写入 `.build/`。

| 目录 | 内容 |
| --- | --- |
| `app/` | C# WPF 界面、托盘、启动和系统进程采样 |
| `src/` | WPF XAML、采集器、状态与校准逻辑；原 2.x 脚本留作迁移参考 |
| `bin/`、`lib/` | npm 命令与运行时安装器 |
| `tests/`、`scripts/` | 测试、打包与校验 |
| `docs/` | 使用说明、架构、视觉与动效规范 |
| `outputs/`、`.build/` | 本机发行包与临时文件，不提交仓库 |

发布流程见 [维护与发布](docs/releasing.md)。

## 许可证

项目采用 [MIT](LICENSE)。随包 Node.js 的许可证见 [LICENSE.node.txt](src/runtime/LICENSE.node.txt)。
