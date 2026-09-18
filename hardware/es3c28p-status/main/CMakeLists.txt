idf_component_register(
    SRCS "main.c"
    INCLUDE_DIRS "."
    REQUIRES driver esp_driver_usb_serial_jtag esp_lcd esp_lcd_ili9341 esp_timer json
)
