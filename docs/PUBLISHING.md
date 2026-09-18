# Publishing / 发布

[English](#english) | [简体中文](#简体中文)

## English

Repository: `littledot2020/codex-finish-shout`. Intended Marketplace publisher: `littledot2020`; register/verify publisher access before publishing. GitHub authentication alone does not grant Marketplace access.

1. Run `npm ci`, `npm test`, `npm run test:backend`, `npm run package`, and `npm run test:package` on Windows. Complete the manual checks in VALIDATION.md.
2. Update both package versions and CHANGELOG/RELEASE notes. Preview versions use odd minor numbers (`0.11.x`); stable uses even (`0.12.x`). Marketplace versions are numeric; use `--pre-release` for the preview channel.
3. Push `main`, wait for CI, then push an immutable `v0.11.0` tag. The workflow creates a bilingual GitHub preview release with VSIX and checksums. Download and retain those exact artifacts for Marketplace.
4. Sign in to https://marketplace.visualstudio.com/manage and create/select the publisher. Upload the same VSIX as a VS Code extension. The publisher must match the manifest; if another ID is needed, update metadata and rebuild before distribution.
5. Review English and Chinese sections, icon, support links and ToolAI promotion in the listing. Validate Marketplace installation and upgrade.
6. Record the published URL and validation results. Stable publishing uses a new version, removes the preview flag in the packaging flow, and follows completed manual acceptance checks.

The extension README contains both languages in one page; Marketplace does not automatically switch separate README files. GitHub has linked English/Chinese homepages. Never commit tokens. Initial Marketplace publication can use web upload; future automation must follow authentication methods supported by the official guide at that time.

With a registered publisher and local `npx vsce login littledot2020` authentication, run `npm run publish:marketplace`. This verifies the checksum and uploads the existing `dist/` preview package without rebuilding it. When using GitHub CI artifacts, copy the release VSIX and SHA256SUMS.txt into `dist/` first.

Reference: https://code.visualstudio.com/api/working-with-extensions/publishing-extension

## 简体中文

仓库：`littledot2020/codex-finish-shout`。计划商店发布者为 `littledot2020`，发布前需注册并确认权限；GitHub 登录不等于已有商店发布权限。

1. 在 Windows 执行 `npm ci`、`npm test`、`npm run test:backend`、`npm run package` 和 `npm run test:package`，完成 VALIDATION.md 中的手工验收。
2. 同步更新两个 package 的版本号及 CHANGELOG/RELEASE 说明。奇数次版本 `0.11.x` 用于预发布，偶数 `0.12.x` 用于正式版。商店版本号只使用三段数字，预发布通过 `--pre-release` 区分。
3. 推送 `main`，CI 通过后推送不可覆盖的 `v0.11.0` 标签。工作流生成双语 GitHub 预发布及 VSIX、校验文件。下载并保留同一份构建产物用于商店上传。
4. 登录 https://marketplace.visualstudio.com/manage，创建或选择发布者，上传同一 VSIX。发布者须与清单一致；若必须改用其他 ID，先更新元信息并重新构建再分发。
5. 检查商店页面中英文说明、图标、支持链接和 ToolAI 推广，验证商店安装及升级。
6. 记录商店地址及验证结果。正式版使用新的版本号，打包时移除预发布标记，且必须先完成手工验收。

扩展 README 在同一页提供完整英文和中文，商店不会自动切换独立的 README。GitHub 使用两个互相链接的首页。令牌不得提交到 Git。首次商店发布可通过网页上传；后续自动化遵循届时官方认证方式。

注册发布者并通过本机 `npx vsce login littledot2020` 认证后，执行 `npm run publish:marketplace`。它校验文件后上传 `dist/` 中已有的预发布包，不重新构建。使用 GitHub CI 产物时，先将 Release 的 VSIX 和 SHA256SUMS.txt 放入 `dist/`。

参考：https://code.visualstudio.com/api/working-with-extensions/publishing-extension
