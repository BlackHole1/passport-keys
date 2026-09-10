// main/pk_app.c: Passport Keys 应用核心。
//
// 线程模型:
//   button 组件任务   pk_app_on_button()   只向队列投递按键事件
//   USB 接收任务      on_usb_line()        解析命令后投递
//   NimBLE host 任务  on_ble_line/link()   解析命令或订阅变化后投递
//   pk_app 任务       app_task()           唯一消费者:发送协议帧、读电量、调背光、加锁更新 LVGL
// 应用状态只在 pk_app 任务中读写,因此不需要额外的锁。
#include "pk_app.h"

#include "bsp_battery.h"
#include "bsp_display.h"
#include "pk_ble.h"
#include "pk_protocol.h"
#include "pk_ui.h"
#include "pk_usb.h"

#include "esp_app_desc.h"
#include "esp_check.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

static const char *TAG = "pk_app";

_Static_assert((int)BSP_BTN_UP == (int)PK_KEY_UP && (int)BSP_BTN_DOWN == (int)PK_KEY_DOWN &&
               (int)BSP_BTN_OK == (int)PK_KEY_OK,
               "bsp_btn_t and pk_key_t must share the same order");

#define EVENT_QUEUE_LEN    16
#define APP_TASK_STACK     4096
#define APP_TASK_PRIO      5
// 没有事件时的巡检周期:刷新连接状态、电量与背光。
#define LOOP_PERIOD_MS     250
// Mac 每 5 秒 ping 一次;15 秒没收到任何命令即认为该链路上的 app 已离线。
#define HOST_TIMEOUT_MS    15000
#define BATTERY_PERIOD_MS  60000
// 可穿戴设备电池只有 520 mAh:空闲超过熄屏时间关闭背光,按键、连接变化或新设置到达时点亮。
// 熄屏时间由 Mac app 的 config 命令下发,只保存在内存里,重启后恢复默认值。
#define BACKLIGHT_ON           80
#define DEFAULT_SCREEN_OFF_MS  10000

typedef enum {
    EV_BUTTON,
    EV_COMMAND,
    EV_BLE_LINK,
} ev_type_t;

typedef struct {
    ev_type_t type;
    pk_link_t link;         // EV_COMMAND
    pk_key_t key;           // EV_BUTTON
    bool subscribed;        // EV_BLE_LINK
    pk_cmd_t cmd;           // EV_COMMAND
} app_event_t;

static QueueHandle_t s_queue;
static bool s_ui_ok;
static bool s_battery_ok;
static uint32_t s_boot_id;
static uint32_t s_seq;
static int64_t s_host_seen_ms[PK_LINK_COUNT];   // 最近一次收到命令的时间;0 表示离线
static bool s_ble_subscribed;
static bool s_usb_present;
static int64_t s_last_activity_ms;
static int64_t s_last_battery_ms;
static int s_battery_soc = -1;
static int s_battery_mv = -1;
static int s_backlight = -1;
static int s_ui_link = -1;
static int64_t s_screen_off_ms = DEFAULT_SCREEN_OFF_MS;   // 0 表示永不熄屏

static int64_t now_ms(void)
{
    return esp_timer_get_time() / 1000;
}

// ---------------------------------------------------------------------------
// 事件生产者:运行在其它任务中,只能投递,不能阻塞。
// ---------------------------------------------------------------------------

void pk_app_on_button(bsp_btn_t btn, bsp_btn_ev_t ev, void *user)
{
    (void)user;
    // 只取按下瞬间:延迟最低,且一次按压只触发一次。之后到来的单击/双击/长按事件忽略。
    if (ev != BSP_BTN_PRESS || !s_queue || (unsigned)btn >= PK_KEY_COUNT) return;
    app_event_t event = { .type = EV_BUTTON, .key = (pk_key_t)btn };
    if (xQueueSend(s_queue, &event, 0) != pdTRUE) {
        ESP_LOGW(TAG, "event queue full, key dropped");
    }
}

static void post_command(pk_link_t link, const char *line, size_t len)
{
    app_event_t event = { .type = EV_COMMAND, .link = link };
    if (!pk_parse_command(line, len, &event.cmd)) return;
    if (xQueueSend(s_queue, &event, 0) != pdTRUE) {
        ESP_LOGW(TAG, "event queue full, command dropped");
    }
}

static void on_usb_line(const char *line, size_t len)
{
    post_command(PK_LINK_USB, line, len);
}

static void on_ble_line(const char *line, size_t len)
{
    post_command(PK_LINK_BLE, line, len);
}

static void on_ble_link(bool subscribed)
{
    app_event_t event = { .type = EV_BLE_LINK, .subscribed = subscribed };
    xQueueSend(s_queue, &event, 0);
}

// ---------------------------------------------------------------------------
// 以下函数只在 pk_app 任务中调用。
// ---------------------------------------------------------------------------

static bool host_alive(pk_link_t link, int64_t now)
{
    return s_host_seen_ms[link] != 0 && now - s_host_seen_ms[link] < HOST_TIMEOUT_MS;
}

static void send_to(pk_link_t link, const char *msg, size_t len)
{
    if (len == 0) return;
    if (link == PK_LINK_USB) {
        pk_usb_send(msg, len);
    } else {
        pk_ble_send(msg, len);
    }
}

static void set_backlight(int level)
{
    if (!s_ui_ok || level == s_backlight) return;
    s_backlight = level;
    bsp_display_backlight((uint8_t)level);
}

static void wake(int64_t now)
{
    s_last_activity_ms = now;
    set_backlight(BACKLIGHT_ON);
}

static void handle_button(pk_key_t key, int64_t now)
{
    char msg[PK_MSG_MAX];
    size_t len = pk_format_button(msg, sizeof(msg), key, ++s_seq, s_boot_id);
    // 两条链路都发,Mac 端按 (boot, seq) 去重。USB 没被 app 打开时写入会在驱动里很快丢弃。
    pk_usb_send(msg, len);
    pk_ble_send(msg, len);

    wake(now);
    if (s_ui_ok) pk_ui_flash_key(key);
}

static void handle_command(pk_link_t link, const pk_cmd_t *cmd, int64_t now)
{
    char msg[PK_MSG_MAX];

    if (cmd->type == PK_CMD_BYE) {
        s_host_seen_ms[link] = 0;
        return;
    }

    bool was_alive = host_alive(link, now);
    s_host_seen_ms[link] = now;

    switch (cmd->type) {
    case PK_CMD_HELLO:
        // 版本号取自应用描述:发布构建为 PROJECT_VER,本地构建为 git describe 的结果。
        send_to(link, msg, pk_format_hello(msg, sizeof(msg), esp_app_get_description()->version, s_boot_id));
        send_to(link, msg, pk_format_battery(msg, sizeof(msg), s_battery_soc, s_battery_mv));
        break;
    case PK_CMD_PING:
        send_to(link, msg, pk_format_pong(msg, sizeof(msg)));
        break;
    case PK_CMD_LABELS:
        for (int i = 0; i < PK_KEY_COUNT; i++) {
            if (cmd->has_label[i] && s_ui_ok) pk_ui_set_label((pk_key_t)i, cmd->label[i]);
        }
        send_to(link, msg, pk_format_ack(msg, sizeof(msg), "labels"));
        break;
    case PK_CMD_CONFIG: {
        int64_t screen_off_ms = (int64_t)cmd->screen_off_s * 1000;
        if (screen_off_ms != s_screen_off_ms) {
            ESP_LOGI(TAG, "screen off after %" PRIu32 " s (0 = never)", cmd->screen_off_s);
            s_screen_off_ms = screen_off_ms;
        }
        send_to(link, msg, pk_format_ack(msg, sizeof(msg), "config"));
        // 按新设置重新计时,用户刚改完设置时屏幕保持点亮。
        wake(now);
        break;
    }
    case PK_CMD_BYE:
        break;
    }

    // 新连上 app 时点亮屏幕,让用户看到连接状态。
    if (!was_alive) wake(now);
}

static void refresh_link_state(int64_t now)
{
    bool usb_present = pk_usb_host_present();
    if (!usb_present) {
        // 拔掉 USB 时收不到 bye:物理连接消失就立即清除该链路,不等 15 秒超时;重新插上后由 app 重新握手。
        s_host_seen_ms[PK_LINK_USB] = 0;
        // Mac app 此刻开始扫描蓝牙,切到快速广播让它尽快发现设备。
        if (s_usb_present) pk_ble_boost_advertising();
    }
    s_usb_present = usb_present;

    pk_ui_link_t link;
    if (host_alive(PK_LINK_USB, now)) {
        link = PK_UI_LINK_USB;
    } else if (host_alive(PK_LINK_BLE, now)) {
        link = PK_UI_LINK_BLE;
    } else if (s_ble_subscribed) {
        link = PK_UI_LINK_BLE_PENDING;
    } else {
        link = PK_UI_LINK_WAITING;
    }

    if ((int)link == s_ui_link) return;
    ESP_LOGI(TAG, "link state %d -> %d", s_ui_link, (int)link);
    s_ui_link = (int)link;
    if (s_ui_ok) pk_ui_set_link(link);
}

static void refresh_battery(int64_t now, bool force)
{
    if (!s_battery_ok || (!force && now - s_last_battery_ms < BATTERY_PERIOD_MS)) return;
    s_last_battery_ms = now;

    // I2C 读取带 100 ms 超时,放在应用任务里执行,不会阻塞按键回调。
    s_battery_soc = bsp_battery_soc();
    s_battery_mv = bsp_battery_mv();
    if (s_ui_ok) pk_ui_set_battery(s_battery_soc);

    char msg[PK_MSG_MAX];
    size_t len = pk_format_battery(msg, sizeof(msg), s_battery_soc, s_battery_mv);
    for (int link = 0; link < PK_LINK_COUNT; link++) {
        if (host_alive((pk_link_t)link, now)) send_to((pk_link_t)link, msg, len);
    }
}

static void refresh_backlight(int64_t now)
{
    bool on = s_screen_off_ms == 0 || now - s_last_activity_ms < s_screen_off_ms;
    set_backlight(on ? BACKLIGHT_ON : 0);
}

static void app_task(void *arg)
{
    (void)arg;
    app_event_t event;

    refresh_battery(now_ms(), true);

    for (;;) {
        if (xQueueReceive(s_queue, &event, pdMS_TO_TICKS(LOOP_PERIOD_MS)) == pdTRUE) {
            int64_t now = now_ms();
            switch (event.type) {
            case EV_BUTTON:
                handle_button(event.key, now);
                break;
            case EV_COMMAND:
                handle_command(event.link, &event.cmd, now);
                break;
            case EV_BLE_LINK:
                s_ble_subscribed = event.subscribed;
                if (!event.subscribed) s_host_seen_ms[PK_LINK_BLE] = 0;
                wake(now);
                break;
            }
        }

        int64_t now = now_ms();
        refresh_link_state(now);
        refresh_battery(now, false);
        refresh_backlight(now);
    }
}

esp_err_t pk_app_start(bool ui_ok, bool battery_ok)
{
    s_ui_ok = ui_ok;
    s_battery_ok = battery_ok;
    s_boot_id = esp_random();
    s_last_activity_ms = now_ms();

    s_queue = xQueueCreate(EVENT_QUEUE_LEN, sizeof(app_event_t));
    ESP_RETURN_ON_FALSE(s_queue, ESP_ERR_NO_MEM, TAG, "event queue alloc failed");

    if (s_ui_ok && pk_ui_init() != ESP_OK) {
        ESP_LOGE(TAG, "UI init failed, continue without screen");
        s_ui_ok = false;
    }
    set_backlight(BACKLIGHT_ON);

    esp_err_t err = pk_usb_start(on_usb_line);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "USB link unavailable: %s", esp_err_to_name(err));
    }
    err = pk_ble_start(on_ble_line, on_ble_link);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "BLE link unavailable: %s", esp_err_to_name(err));
    }

    BaseType_t ok = xTaskCreate(app_task, "pk_app", APP_TASK_STACK, NULL, APP_TASK_PRIO, NULL);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "app task create failed");

    ESP_LOGI(TAG, "ready: boot=%08" PRIx32 " ui=%d battery=%d", s_boot_id, s_ui_ok, s_battery_ok);
    return ESP_OK;
}
