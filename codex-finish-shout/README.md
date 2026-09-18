# Bundled backend / 内置后端

[English user guide](../README.md) | [中文使用说明](../README.zh-CN.md)

## English

This directory is the canonical source of the Windows PowerShell backend and original music. The VS Code build copies its runtime resources into the VSIX. Most users should install the VSIX and use Initialize Backend, Repair / Update Backend, Check Backend Status and Uninstall Backend in the Command Palette.

For source-based installation, run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/install.ps1`. Manage with `scripts/manage.ps1 Status`, `Enable`, `Disable`, or `Stop`. Installer operations accept `-TargetRoot` for an isolated Codex root. Do not use your production profile for development testing.

The default settings are in `config/default-settings.json`. Built-in audio uses `builtin:soft-chime`, `builtin:bright-finish`, or `builtin:gentle-rise`. Personal file paths remain supported. Quiet hours and optional serial hardware are configured in the user settings file. Hardware is off by default in new installs. Existing explicit settings survive upgrades.

Initialization backs up and updates user-level notify and six lifecycle Hook handlers, preserving unrelated handlers. Trust must be granted in Codex before real activity can be observed. Existing unrelated notify settings cause installation to stop; replacement is an explicit advanced `-Force` operation. Uninstall restores the previously saved handler when applicable and preserves user data.

Audio is played only after project-wide idle confirmation. Parallel activity or a newer prompt cancels a stale completion candidate. Playback is queued across projects. Hook definitions and notification compatibility depend on the installed Codex version; see the release validation notes.

## 简体中文

本目录是 Windows PowerShell 后端和原创音乐的唯一源文件位置；构建时将运行资源复制到 VSIX。普通用户安装 VSIX 后，通过命令面板的初始化后端、修复／更新后端、检查后端状态和卸载后端操作即可。

源码安装可执行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/install.ps1`，通过 `scripts/manage.ps1 Status`、`Enable`、`Disable` 或 `Stop` 管理。安装管理支持 `-TargetRoot` 指定隔离的 Codex 根目录，开发测试不要使用日常账户目录。

默认配置位于 `config/default-settings.json`。内置音乐使用 `builtin:soft-chime`、`builtin:bright-finish`、`builtin:gentle-rise`；同时支持个人音频路径。用户配置可设置免打扰和可选串口硬件，全新安装默认关闭硬件，升级保留已有明确设置。

初始化备份并更新用户级 notify 与六种生命周期 Hook，保留其他处理器。必须在 Codex 中完成信任授权才能观察真实活动。已有其他 notify 配置时安装停止，替换需要高级用户明确使用 `-Force`。卸载在适用时恢复保存过的处理器，并保留个人数据。

只有项目整体通过静默确认后才播放音乐；并行活动或新提示词会取消旧完成候选。多项目音频按队列播放。Hook 定义和通知兼容性依赖已安装 Codex 版本，详见发布验证记录。

## Promotion / 推广

[ToolAI · Discover AI tools, models and open-source projects / 探索 AI 工具、模型与开源项目](https://www.toolai.io/)
