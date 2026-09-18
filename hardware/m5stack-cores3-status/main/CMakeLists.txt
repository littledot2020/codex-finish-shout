idf_component_register(
    SRCS "main.c"
    INCLUDE_DIRS "."
    REQUIRES m5stack_core_s3_noglib esp_driver_usb_serial_jtag esp_lcd
)
