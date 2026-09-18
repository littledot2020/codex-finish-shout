# Development / 开发

[English](#english) | [简体中文](#简体中文)

## English

Use Windows x64, Node.js 24, npm, Windows PowerShell 5.1, and VS Code. Run `npm ci`, then `npm test` and `npm run test:backend`. All automated backend fixtures use temporary directories and suppress audio.

`codex-finish-shout/` owns the backend, defaults, and the single source of music assets. `codex-finish-shout-controls/` owns the VS Code interface. `npm run build` copies runtime resources into ignored generated directories under the extension; do not edit those copies.

Press F5 to launch a separate development host with `.dev/vscode` user data and `CODEX_FINISH_SHOUT_DEV_ROOT` set to `.dev/codex`. It overrides normal backend paths without changing your real `CODEX_HOME`. Run `npm run dev:simulate` to populate two synthetic projects. Do not install the backend for the default simulation workflow: its worker can replace simulated snapshots. Use a separate Windows account to validate real Codex hooks.

Use short `feature/*` branches and merge tested changes into `main`. `npm run package` emits a Windows x64 preview VSIX and SHA-256 file in `dist/`. `npm run test:package` extracts and tests that package in an isolated temporary path, with no dependency on the source directory.

For a debug upgrade, restart the development host after rebuilding. For release upgrades, install the new VSIX and run Repair / Update Backend. Avoid running old and new publisher identities concurrently.

## 简体中文

使用 Windows x64、Node.js 24、npm、Windows PowerShell 5.1 和 VS Code。执行 `npm ci`，再运行 `npm test` 和 `npm run test:backend`。后端自动测试使用临时目录并禁止音频输出。

`codex-finish-shout/` 保存后端、默认配置和唯一的音乐源文件；`codex-finish-shout-controls/` 保存 VS Code 界面。`npm run build` 将运行资源复制到扩展目录下被 Git 忽略的生成目录，不要修改这些副本。

按 F5 启动独立开发窗口，用户数据写入 `.dev/vscode`，通过 `CODEX_FINISH_SHOUT_DEV_ROOT` 将插件后端路径隔离到 `.dev/codex`，不修改真实 `CODEX_HOME`。执行 `npm run dev:simulate` 生成两个模拟项目。默认模拟流程不安装后端，避免后台工作进程替换模拟快照；真实 Hook 联调使用独立 Windows 账户。

使用短期 `feature/*` 分支，测试通过后合入 `main`。`npm run package` 在 `dist/` 生成 Windows x64 预发布 VSIX 和 SHA-256 文件。`npm run test:package` 将该包解压到隔离的临时目录进行安装测试，不依赖源码目录。

调试升级需要重新构建并重启开发窗口；发布包升级需要安装新 VSIX，再执行修复／更新后端。避免旧、新发布者版本同时运行。
