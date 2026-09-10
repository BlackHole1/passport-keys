// main/pk_ui.h: Passport Keys 主屏:连接状态、三键映射标签、电量。
#pragma once

#include "esp_err.h"
#include "pk_protocol.h"

typedef enum {
    PK_UI_LINK_WAITING = 0,     // 没有 app 连接
    PK_UI_LINK_BLE_PENDING,     // Mac 已订阅 BLE 通知,等待 app 握手
    PK_UI_LINK_USB,
    PK_UI_LINK_BLE,
} pk_ui_link_t;

// 以下函数内部获取 LVGL 锁,只能从非 LVGL 任务调用;拿不到锁时放弃本次刷新。
esp_err_t pk_ui_init(void);
void pk_ui_set_link(pk_ui_link_t link);
// label 为空字符串时显示 "--"。
void pk_ui_set_label(pk_key_t key, const char *label);
// 按键反馈:对应行高亮约 180 ms,吉祥物跳一下。
void pk_ui_flash_key(pk_key_t key);
// soc < 0 表示读不到电量,隐藏电量显示。
void pk_ui_set_battery(int soc);
