# 维护与发布

项目支持完整 ZIP 和 npm tarball 两种发行格式，均包含 Node.js 24.12.0 Windows x64 运行时。Git 源码仅记录运行时版本、官方 URL、许可证和 SHA-256。

## 本机发布检查

1. 同时更新 `package.json` 和 `src/version.json` 的版本号，补充 `CHANGELOG.md`。
2. 执行 `npm test` 和 `npm run test:ui`。
3. 执行 `scripts/package.ps1`、`scripts/verify-package.ps1`、`scripts/package-npm.ps1` 和 `scripts/test-npm.ps1`。
4. 在 GitHub 创建对应版本的 Release，上传 `outputs/` 下该版本的 ZIP、TGZ 及两个 SHA-256 文件。

打包使用文件清单；缓存、日志、个人设置与本机验证原始记录不发布。发布前检查 `git diff --cached`，不提交本机路径或会话信息。

## 自动化

`verify.yml` 在 Windows 上执行单元测试、打包和离线安装验证。`release.yml` 支持手动运行或版本标签推送；它执行同样的验证，再上传完整发行包。WPF 视觉与动效自检在本机运行，避免把无交互桌面的 CI 当成视觉验证。

同一版本的 Release 不覆盖已有附件；修复发行内容时增加版本号。源码中的 npm 包信息仅准备了发布格式，当前发行渠道为 GitHub Release。将来发布到 npmjs 需要维护者账号与相应的发布认证。

## 运行时更新

更新 `runtime.json` 的版本、官方 URL 与 SHA-256，同时更新 `src/runtime/README.txt` 和对应版本的 Node.js 许可证。重新下载、执行测试和离线安装验证后发布；不要用本机 PATH 中任意版本替换固定运行时。
