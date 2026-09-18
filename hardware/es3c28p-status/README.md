# ES3C28P Codex 项目状态板

这是本插件配套的 ESP-IDF 5.4.x 固件，目标为标注 **ES3C28P** 的 LCDWiki 2.8 英寸 ESP32-S3 N16R8 板卡。它不适用于微雪 `ESP32-S3-Touch-LCD-2.8` 等同尺寸但屏幕、音频芯片或 GPIO 不同的板卡。

插件观察到 Codex 生命周期变化后，固件会：

- 在 ILI9341 横屏上显示最多 6 行项目名称；
- 每行右侧显示状态徽标：红色 `RUN` 表示运行中，绿色 `DONE` 表示完成；
- 项目超过 6 个时在首行右上角显示 `6/总数`，主机优先发送运行中的项目；
- 确认某个任务完成时，通过 ES8311 + I2S 在外接喇叭播放内置庆祝旋律；
- 通过板载 USB Serial/JTAG 接收插件消息，无需额外 USB-UART 转换器。

启动后、尚未收到主机快照时，屏幕显示 `WAITING FOR HOST`；收到总数为 0 的有效快照后显示 `Codex ready`。项目快照本身不播放声音，只有兼容的完成消息会触发旋律。

固件带有 90 秒主机快照看门狗。最后一条有效 `project_snapshot` 超过 90 秒没有续期时，旧项目和旧数字会被清除，屏幕改为 `HOST OFFLINE`。恢复收到有效快照后会立即回到最新项目列表；看门狗切换和快照恢复均不会触发音频。

## 准备

- ESP-IDF 5.4.x（本工程已用 5.4.4 编译通过）；
- 可传数据的 USB-C 线；
- 已安装或更新本 Codex 插件的运行脚本；
- 如需声音，在板卡 1.25 mm 2P 喇叭座外接 1.5 W/8 Ω 或 2 W/4 Ω 扬声器。ES3C28P 没有板载扬声器。

## 编译

ESP-IDF 5.4 的 Windows Kconfig 工具不能稳定处理本仓库的中文路径。在 **ESP-IDF 5.4 PowerShell/Terminal** 中，先把权威源文件复制到纯 ASCII 工作目录，再编译：

```powershell
$source = (Resolve-Path .\hardware\es3c28p-status).Path
$work = 'C:\esp-work\es3c28p-status'

New-Item -ItemType Directory -Force -Path $work, "$work\main" | Out-Null
Copy-Item -Force `
  "$source\CMakeLists.txt", `
  "$source\dependencies.lock", `
  "$source\partitions.csv", `
  "$source\sdkconfig.defaults" `
  -Destination $work
Copy-Item -Force -Recurse "$source\main\*" "$work\main"

Set-Location $work
idf.py set-target esp32s3
idf.py build
```

首次构建可能需要联网解析 ESP-IDF managed components。后续修改源码后，重新执行上面的复制步骤再增量编译。

仓库内还提供不依赖板卡的静态守护逻辑检查，可在仓库根目录运行：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\hardware\es3c28p-status\tests\verify_snapshot_watchdog.ps1
```

该检查确认超时常量、合法快照续期、离线清屏以及快照/超时路径不触发音频；最终仍应以上述 ESP-IDF 实际编译为准。

## 烧录

连接板卡并在设备管理器中确认 COM 口，然后在 ASCII 工作目录执行：

```powershell
idf.py -p COM5 flash monitor
```

将 `COM5` 换成实际端口。如无法进入下载模式，按住 **BOOT**，按下并松开 **RESET/EN**，再松开 **BOOT** 后重试。

烧录后可先用 monitor 确认启动日志。联调插件前必须用 `Ctrl+]` 退出 monitor；同一 COM 口不能同时被 monitor 和插件占用。

## 与插件联调

`codex-finish-shout/scripts/codex-finish-shout-hook.ps1` 会在 lifecycle 状态变化后发送一行 UTF-8 项目快照；后台同步器也会在集合变化时立即发送，并在无变化时每 30 秒重发：

```json
{"version":1,"type":"project_snapshot","total":3,"projects":[{"name":"alpha","status":"running"},{"name":"beta","status":"completed"},{"name":"demo","status":"completed"}]}
```

`project_snapshot` 的字段含义：

- `version` 必须为 `1`；
- `total` 是聚合状态中的项目总数，可大于本次 `projects` 数组长度；
- `projects` 最多显示前 6 项，每项使用 `name` 和 `status`；只有 `status="completed"` 显示绿色，其余状态按红色运行态处理。

一条合法快照要求 `total` 是非负整数、`projects` 是不超过 6 项的数组、`total` 不小于本次数组长度，并且每个项目都有字符串类型的 `name` 和 `status`。`total=0` 与空数组是合法心跳，会清空列表并显示 `Codex ready`。语法错误、字段错误、项目项错误以及超长后被丢弃的 JSON 都不会刷新 90 秒看门狗。

主机正在等待项目级静默确认时仍发送 `running`，因此连续任务之间屏幕保持红色；最终候选持续空闲默认 10 秒后才变绿，并在插件未停用且不处于免打扰时触发一次旋律。此行为由主机插件控制，固件协议不变。

主机发送到板卡的项目名会按完整 UTF-8 字符截断到最多 48 字节，并根据屏幕宽度再次裁切。每条 JSON 必须以 LF 结束；固件接收缓冲区为 8192 字节，而当前主机串口传输层把单行限制在 2048 字节以内。超长行会被整行丢弃，并在下一个 LF 处重新同步。

固件也兼容旧版完成消息：

```json
{"version":1,"type":"completion","status":"completed","project":"demo","message":"完成","background":"#16A34A","foreground":"#FFFFFF","eventId":"turn-id","projectKey":"sha256"}
```

呈现未被停用或免打扰抑制时，主机确认完成后先发送该 `completion` 消息以触发旋律并兼容 M5Stack CoreS3，再发送最新 `project_snapshot`。ES3C28P 已进入项目列表模式时，会把同名项目更新为绿色并保持列表视图；未收到项目快照时仍可显示旧版滚动完成页。`eventId` 和 `projectKey` 是主机侧跟踪字段，固件不使用。

在仓库根目录退出 monitor 后，可发送一次无电脑音频的测试完成事件：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\manage.ps1 Test -NoAudio
```

返回结果中应看到 `BoardNotified = true`、实际 `BoardPort`、`BoardReason = sent`，以及完成消息/项目快照的发送结果。测试会触发外接喇叭的庆祝旋律，但不会播放电脑音频。

## 串口配置

单独连接一块 Espressif USB Serial/JTAG 板时，插件默认会自动发现。多个 Espressif 板卡或多个 USB 串口同时存在时，应在 `%USERPROFILE%\.codex\codex-finish-shout.json` 的现有配置中合并（不要覆盖其他音频设置）：

```json
{
  "hardware": {
    "enabled": true,
    "transport": "serial",
    "port": "COM5",
    "autoDetect": false,
    "baudRate": 115200,
    "timeoutMilliseconds": 1000,
    "message": "完成",
    "backgroundColor": "#16A34A",
    "foregroundColor": "#FFFFFF"
  }
}
```

USB Serial/JTAG 实际不依赖串口波特率；`baudRate` 用于与 .NET 串口 API 的配置保持一致。

## 引脚和字体限制

- LCD：SCLK=12、MOSI=11、MISO=13、DC=46、CS=10、BL=45；LCD RST 与 ESP32-S3 `EN/CHIP_PU` 共用。
- I2C：SDA=16、SCL=15，ES8311 地址为 `0x18`。
- I2S：MCLK=4、BCLK=5、LRCK=7、ESP TX / ES8311 DSDIN=8；ES8311 ASDOUT / ESP RX=6，本固件未使用录音方向。
- 功放使能：GPIO1 低电平有效。

为减小固件，内置字库支持 ASCII 以及“完成进度插件公司”八个常用中文字形；其他中文字在屏幕上显示为 `?`。音频为固件实时生成的短旋律，不依赖 SD 卡或 MP3 文件。
