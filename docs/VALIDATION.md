# Validation / 验证记录

Automated verification is recorded before publication. It cannot establish audible output or compatibility with every Codex version. / 发布前记录自动验证结果；自动测试不能证明实际听感，也不能代替全部 Codex 版本兼容性验证。

| Check / 检查 | Status / 状态 |
|---|---|
| JavaScript regression suite / JavaScript 回归 | 95 passed, including concurrent initialization / 95 项通过，含并发初始化 |
| PowerShell backend suite / 后端测试 | 106 passed; bundled audio suite passed / 106 项及内置音频测试通过 |
| Extracted VSIX install and upgrade / 解包安装升级 | Passed, including injected failure rollback / 通过，含故障注入回滚 |
| Promotion language and persistence / 推广语言和持久化 | Unit, Chromium and VS Code host checks passed / 单元、浏览器和宿主验证通过 |
| Clean Windows account and audible cues / 干净账户实际听音 | Manual check required / 待手工验证 |
| Installed VS Code 1.136.1 host / 已安装宿主 | Activation, commands, language and promotion settings passed / 激活、命令、语言和推广设置通过 |
| Minimum VS Code 1.90.0 / 最低宿主 | Passed in GitHub Windows CI / GitHub Windows CI 通过 |
| Stable VS Code 1.138.0 / 当前稳定宿主 | Passed in GitHub Windows CI / GitHub Windows CI 通过 |
| Real Codex Hook authorization and completion / 真实授权及完成 | Manual check required / 待手工验证 |
| Marketplace install and upgrade / 商店安装升级 | Requires publication / 待上架后验证 |

Publish as preview until manual acceptance is complete. / 手工验收完成前仅发布预览版。

Chromium checks cover English/Chinese, dark/light/high-contrast themes, keyboard access, and widths from 260 to 1080 px. Screenshots use synthetic tasks. / Chromium 验证覆盖中英文、深浅与高对比主题、键盘操作及 260–1080 像素宽度，截图使用模拟任务。

Verified on 2026-09-18. [Initial successful Windows CI](https://github.com/littledot2020/codex-finish-shout/actions/runs/35352938424). Every release tag reruns these checks before publishing its artifacts. / 验证日期：2026-09-18；每个发布标签重新验证后才发布产物。
