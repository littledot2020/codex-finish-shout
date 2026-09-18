# 硬件配套工程

- [ES3C28P Codex 项目状态板](./es3c28p-status/README.md)：LCDWiki ESP32-S3 + ILI9341，最多显示 6 行项目；红色 `RUN` 表示运行中，绿色 `DONE` 表示完成。未被停用或免打扰抑制时，确认完成会通过 ES8311 + I2S 在外接喇叭播放庆祝旋律。
- [M5Stack CoreS3 状态板](./m5stack-cores3-status/README.md)：兼容旧 `completion` 协议，只显示单次完成页，不显示全部项目列表。

主机通过一行一个的 UTF-8 JSON 通信。ES3C28P 同时支持 `project_snapshot` 和旧 `completion`；M5Stack CoreS3 只支持旧 `completion`。仅连接一块 Espressif USB Serial/JTAG 板时可使用插件的自动发现；多板或多串口环境请在用户配置的 `hardware.port` 中固定 COM 口。确认完成时优先使用板卡呈现；只有串口缺席、被占用或发送失败时，才回退到电脑弹层和音频。

Controls 0.7.0 负责发布工作区租约并保证后台同步器存活；同步器在项目集合变化时立即发送全量快照，并在无变化时每 30 秒重发。ES3C28P 连续 90 秒没有收到合法快照会清除旧项目并显示 `HOST OFFLINE`，恢复通信后自动重建列表；这些同步帧不会播放完成旋律。

连续提交多个 Codex 任务时，主机会在默认 10 秒项目级静默确认期内继续发送红色 `RUN`；只有最终任务稳定结束后才发送绿色 `DONE`，并在呈现未被抑制时播放一次庆祝旋律。

ES3C28P 工程应从本仓库复制到纯 ASCII 路径后使用 ESP-IDF 5.4.x 构建；其内置字库只包含 ASCII 和“完成进度插件公司”，其他中文字显示为 `?`。具体接线、喇叭、编译和烧录限制见各工程说明。
