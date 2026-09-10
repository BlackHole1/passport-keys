// main/pk_app.h: Passport Keys 应用核心:事件队列、链路状态、屏幕与背光。
#pragma once

#include "bsp_button.h"
#include "esp_err.h"

#include <stdbool.h>

typedef enum {
    PK_LINK_USB = 0,
    PK_LINK_BLE,
    PK_LINK_COUNT,
} pk_link_t;

// 建立事件队列,初始化屏幕、USB 与 BLE 链路,并启动应用任务。
// ui_ok=false 时不访问 LVGL 与背光;battery_ok=false 时电量上报为 -1。
// 单条链路启动失败只记录日志,另一条链路仍然可用。
esp_err_t pk_app_start(bool ui_ok, bool battery_ok);

// 传给 bsp_button_init() 的回调。运行在 button 组件任务中,只向队列投递事件,不阻塞。
void pk_app_on_button(bsp_btn_t btn, bsp_btn_ev_t ev, void *user);
