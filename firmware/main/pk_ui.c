// main/pk_ui.c: Passport Keys 主屏。
// 沿用 ui_pixel 主题(天空、草地、标题牌、吉祥物、墨线面板)。
//
// 240 x 320 竖屏布局(y 坐标):
//   8-45    标题牌 "MAC KEYS";右上角云朵下方 (162, 28) 显示电量
//   54-94   连接状态面板
//   100-236 三个按键行,每行 38 px 高、间隔 46 px
//   240-288 吉祥物,286 以下是草地
#include "pk_ui.h"

#include "bsp_display.h"
#include "ui_pixel.h"

#include "lvgl.h"

#include <stdint.h>

#define LOCK_TIMEOUT_MS  200
#define FLASH_MS         180
#define MASCOT_X         101
#define MASCOT_Y         240

static lv_obj_t *s_battery;
static lv_obj_t *s_status;
static lv_obj_t *s_mascot;
static lv_obj_t *s_rows[PK_KEY_COUNT];
static lv_obj_t *s_values[PK_KEY_COUNT];
static lv_timer_t *s_flash_timers[PK_KEY_COUNT];

static const char *const KEY_TITLES[PK_KEY_COUNT] = {
    LV_SYMBOL_UP "  UP",
    LV_SYMBOL_DOWN "  DOWN",
    LV_SYMBOL_OK "  OK",
};

// ui_pixel 面板默认 7 px 内边距加 4 px 边框,38 px 高的面板放不下一行 14 号字,这里收紧纵向内边距。
static lv_obj_t *compact_panel(lv_obj_t *parent, int y, int h)
{
    lv_obj_t *panel = ui_pixel_panel_create(parent, 12, y, 212, h, UI_PAPER);
    lv_obj_set_style_pad_hor(panel, 8, 0);
    lv_obj_set_style_pad_ver(panel, 0, 0);
    return panel;
}

esp_err_t pk_ui_init(void)
{
    if (!bsp_lvgl_lock(1000)) return ESP_ERR_TIMEOUT;

    lv_obj_t *scr = ui_pixel_screen_create("MAC KEYS");

    s_battery = ui_pixel_label(scr, "", &lv_font_montserrat_14, UI_INK);
    lv_obj_set_width(s_battery, 72);
    lv_obj_set_style_text_align(s_battery, LV_TEXT_ALIGN_RIGHT, 0);
    lv_obj_set_pos(s_battery, 162, 28);

    lv_obj_t *status_panel = compact_panel(scr, 54, 34);
    s_status = ui_pixel_label(status_panel, "", &lv_font_montserrat_14, UI_INK);
    lv_obj_center(s_status);

    for (int i = 0; i < PK_KEY_COUNT; i++) {
        s_rows[i] = compact_panel(scr, 100 + i * 46, 38);

        lv_obj_t *title = ui_pixel_label(s_rows[i], KEY_TITLES[i], &lv_font_montserrat_14, UI_INK);
        lv_obj_align(title, LV_ALIGN_LEFT_MID, 0, 0);

        s_values[i] = ui_pixel_label(s_rows[i], "--", &lv_font_montserrat_14, UI_SKY_DARK);
        lv_label_set_long_mode(s_values[i], LV_LABEL_LONG_DOT);
        lv_obj_set_width(s_values[i], 120);
        lv_obj_set_style_text_align(s_values[i], LV_TEXT_ALIGN_RIGHT, 0);
        lv_obj_align(s_values[i], LV_ALIGN_RIGHT_MID, 0, 0);
    }

    s_mascot = ui_pixel_mascot_create(scr, MASCOT_X, MASCOT_Y);
    lv_screen_load(scr);
    bsp_lvgl_unlock();

    pk_ui_set_link(PK_UI_LINK_WAITING);
    pk_ui_set_battery(-1);
    return ESP_OK;
}

void pk_ui_set_link(pk_ui_link_t link)
{
    static const struct {
        const char *text;
        uint32_t color;
    } STATES[] = {
        [PK_UI_LINK_WAITING]     = { "WAITING FOR MAC", UI_INK },
        [PK_UI_LINK_BLE_PENDING] = { LV_SYMBOL_BLUETOOTH "  CONNECTING", UI_SKY_DARK },
        [PK_UI_LINK_USB]         = { LV_SYMBOL_USB "  USB CONNECTED", UI_GRASS_DARK },
        [PK_UI_LINK_BLE]         = { LV_SYMBOL_BLUETOOTH "  BLE CONNECTED", UI_GRASS_DARK },
    };

    if ((unsigned)link >= sizeof(STATES) / sizeof(STATES[0]) || !s_status) return;
    if (!bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    lv_label_set_text(s_status, STATES[link].text);
    lv_obj_set_style_text_color(s_status, lv_color_hex(STATES[link].color), 0);
    bsp_lvgl_unlock();
}

void pk_ui_set_label(pk_key_t key, const char *label)
{
    if ((unsigned)key >= PK_KEY_COUNT || !s_values[key]) return;
    if (!bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    lv_label_set_text(s_values[key], label[0] ? label : "--");
    bsp_lvgl_unlock();
}

// lv_timer 回调运行在 LVGL 任务里,已持有锁。repeat_count=1 的定时器执行后由 LVGL 自动删除。
static void flash_end(lv_timer_t *timer)
{
    intptr_t key = (intptr_t)lv_timer_get_user_data(timer);
    ui_pixel_set_selected(s_rows[key], false, true);
    s_flash_timers[key] = NULL;
}

void pk_ui_flash_key(pk_key_t key)
{
    if ((unsigned)key >= PK_KEY_COUNT || !s_rows[key]) return;
    if (!bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;

    ui_pixel_set_selected(s_rows[key], true, true);
    if (s_flash_timers[key]) {
        lv_timer_reset(s_flash_timers[key]);
    } else {
        s_flash_timers[key] = lv_timer_create(flash_end, FLASH_MS, (void *)(intptr_t)key);
        lv_timer_set_repeat_count(s_flash_timers[key], 1);
    }

    // ui_pixel_mascot_jump() 以当前 y 为起点;连按时上一次动画还没结束会让吉祥物越跳越高,
    // 先停掉动画并归位。
    lv_anim_delete(s_mascot, NULL);
    lv_obj_set_y(s_mascot, MASCOT_Y);
    ui_pixel_mascot_jump(s_mascot);

    bsp_lvgl_unlock();
}

void pk_ui_set_battery(int soc)
{
    if (!s_battery || !bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    if (soc < 0) {
        lv_label_set_text(s_battery, "");
    } else {
        const char *icon = soc >= 90 ? LV_SYMBOL_BATTERY_FULL
                         : soc >= 65 ? LV_SYMBOL_BATTERY_3
                         : soc >= 40 ? LV_SYMBOL_BATTERY_2
                         : soc >= 15 ? LV_SYMBOL_BATTERY_1
                                     : LV_SYMBOL_BATTERY_EMPTY;
        lv_label_set_text_fmt(s_battery, "%s %d%%", icon, soc);
        lv_obj_set_style_text_color(s_battery, lv_color_hex(soc < 15 ? UI_RED : UI_INK), 0);
    }
    bsp_lvgl_unlock();
}
