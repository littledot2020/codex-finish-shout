# M5Stack CoreS3-SE completion display

This ESP-IDF application listens on the board's USB Serial/JTAG interface. A
completion message is one JSON object per line:

```json
{"type":"completion","status":"completed","project":"my-project","message":"完成","background":"#16A34A","foreground":"#FFFFFF"}
```

The screen shows the project name and `完成` on a green background. The host
plugin auto-detects Espressif USB Serial/JTAG devices; on the current machine
the board is `COM5`. No separate UART adapter and no OpenOCD session are needed
for this display protocol.

The CoreS3-SE must be powered on with its left power button. USB flashing can
still succeed while the board's display/power-management peripherals are off.

## Build and flash

Use ESP-IDF v6.0.2, target `esp32s3`, and flash with:

```powershell
idf.py set-target esp32s3
idf.py build
idf.py -p COM5 flash
```

The source is kept in the workspace under `hardware/m5stack-cores3-status`.
The ESP-IDF 6.0.2 Windows Kconfig step can mishandle the workspace's Chinese
path, so the verified build uses an ASCII working copy at
`D:\codex_finish_display_build`; the source files remain authoritative in this
directory.
