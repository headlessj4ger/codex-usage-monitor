# Code signing policy

3.0.0 在迁移验证阶段。项目尚未取得签名证书，也未加入 SignPath Foundation。候选 ZIP 与 tgz 可用于测试；公开稳定发行须通过可信签名和签名后验收。

项目只在用户本机读取 Codex 会话元数据和日志，将统计结果保存在用户指定的本地目录。运行时不向网络传输会话信息，也不读取 Codex 登录凭据。维护者从源码构建时会从 Node.js 官方下载固定运行时；二进制安装包自带运行时。

## 申请与配置

[SignPath Foundation 条件](https://signpath.org/terms) 要求项目近况、公开源码与开源许可、已发布的同类制品、维护者多因素认证、可核实的项目信誉和每次签名的人工审核。仓库已采用 MIT，现有公开发行是 2.x；应由维护者向基金会确认其是否接受 3.x 的 C# 原生候选制品作为迁移后的签名目标。资格和审核结果由基金会决定。

1. 维护者确认 GitHub 多因素认证，以项目身份填写 [申请表](https://signpath.org/apply)，并提供仓库、发行历史及可复现构建链接。获批后在 README 和下载页面按要求披露签名方、代码维护人、审查人及签名批准人。
2. 配置 [SignPath 的 GitHub Trusted Build System](https://docs.signpath.io/trusted-build-systems/github)。给申请批准的项目设立只签 `CodexUsageMonitor.exe` 和 `CodexUsageMonitor.dll` 的 ZIP 制品配置，验证产品名和版本元数据。随包的 Node 和 .NET 文件沿用上游签名。
3. 在 GitHub 的 `windows-signing` 环境仅授权主分支，添加受限范围的 `SIGNPATH_API_TOKEN` 密钥，配置 `SIGNPATH_ORGANIZATION_ID`、`SIGNPATH_PROJECT_SLUG`、`SIGNPATH_POLICY_SLUG` 和 `SIGNER_THUMBPRINT`。保留人工签名批准。
4. 手动运行 `release.yml`。流程校验有效的 RSA 签名、证书指纹和时间戳，用同一份签名文件生成 ZIP 和 tgz，并上传到 Release 草稿。维护者从草稿下载制品，在启用目标安全策略的 Windows 11 上验收实际启动、安装和升级，再正式发布。[Microsoft 的签名说明](https://learn.microsoft.com/windows/apps/develop/smart-app-control/code-signing-for-smart-app-control)。

## npmjs

GitHub Release 的 tgz 可直接由 npm 安装，不要求安装者登录。若要提供 `npm install -g codex-usage-monitor`，维护者须确认包名归属并完成 [npm 发布认证](https://docs.npmjs.com/requiring-2fa-for-package-publishing-and-settings-modification/)。首次发布使用已验收的签名 tgz，执行 `npm publish ./codex-usage-monitor-3.0.0.tgz --access public`，并由维护者完成 2FA。后续可绑定 [Trusted Publishing](https://docs.npmjs.com/trusted-publishers/) 使用 OIDC 并暂存发布供人工批准，无需将 npm 发布令牌存入仓库。

测试分支和候选文件不抢占正式 npm 版本，也不覆盖历史 GitHub Release。
