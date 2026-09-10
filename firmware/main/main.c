// main/main.c: Passport Keys 固件入口。
//
// 把 Passport 的上/下/确认三个功能键通过 USB 串口或 BLE 发送给 macOS 上的 Passport Keys app,
// 由 app 把按键映射成系统快捷键。协议见 pk_protocol.h。
//
// 初始化顺序:共享 I2C → 显示/LVGL → 电池 → 应用任务与 USB/BLE 链路 → 按键。
// 按键放在最后,保证第一次按键回调发生时事件队列已经建立。
#include "bsp_battery.h"
#include "bsp_button.h"
#include "bsp_display.h"
#include "bsp_i2c.h"
#include "bsp_pins.h"
#include "pk_app.h"

#include "esp_app_desc.h"
#include "esp_log.h"

static const char *TAG = "main";

void app_main(void)
{
    ESP_LOGI(TAG, "Passport Keys %s", esp_app_get_description()->version);

    bsp_i2c_init();

    // 屏幕只用于显示状态;失败时按键转发照常工作,因此不中止启动。
    bool ui_ok = bsp_display_init() == ESP_OK && bsp_lvgl_init() != NULL;
    if (!ui_ok) {
        ESP_LOGE(TAG, "显示/LVGL 初始化失败,以无屏模式继续。检查 SPI 接线(MOSI=%d SCLK=%d CS=%d DC=%d BL=%d)",
                 BSP_LCD_MOSI, BSP_LCD_SCLK, BSP_LCD_CS, BSP_LCD_DC, BSP_LCD_BL);
    }

    bool battery_ok = bsp_battery_init() == ESP_OK;
    if (!battery_ok) {
        ESP_LOGW(TAG, "电量计不可用,不显示电量");
    }

    if (pk_app_start(ui_ok, battery_ok) != ESP_OK) {
        ESP_LOGE(TAG, "应用启动失败");
        return;
    }

    if (bsp_button_init(pk_app_on_button, NULL) != ESP_OK) {
        ESP_LOGE(TAG, "按键初始化失败,检查 GPIO%d 的 ADC 分压", BSP_BTN_ADC_CHANNEL);
    }
}
