idf_component_register(
    SRCS "main.c"
         "pk_app.c"
         "pk_ble.c"
         "pk_protocol.c"
         "pk_ui.c"
         "pk_usb.c"
         "ui_pixel.c"
         "ui_pixel_math.c"
    INCLUDE_DIRS "."
    REQUIRES bsp bt esp_app_format esp_driver_usb_serial_jtag esp_hw_support esp_timer nvs_flash vfs
)
