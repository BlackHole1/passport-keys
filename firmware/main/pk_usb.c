// main/pk_usb.c: USB Serial/JTAG 链路。
//
// 默认控制台以非驱动模式直接写 USB FIFO,无法阻塞读取主机数据。这里安装驱动并让 VFS 走驱动:
//   - 接收任务阻塞在 usb_serial_jtag_read_bytes() 上读取 Mac 命令;
//   - 协议帧与 ESP_LOG 日志都经过 VFS 的写锁和驱动的发送缓冲,同一行内不会互相穿插。
// Mac 端从行内 {"t": 处开始解析,其余日志内容会被忽略。
#include "pk_usb.h"

#include "pk_protocol.h"

#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "esp_check.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

static const char *TAG = "pk_usb";

#define RX_TASK_STACK  3072
#define RX_TASK_PRIO   4

static pk_usb_line_cb_t s_on_line;
// 只在接收任务中访问;放在静态区,避免占用任务栈。
static pk_line_t s_line;

static void dispatch_line(const char *line, size_t len, void *user)
{
    (void)user;
    s_on_line(line, len);
}

static void rx_task(void *arg)
{
    (void)arg;
    uint8_t buf[64];
    for (;;) {
        int n = usb_serial_jtag_read_bytes(buf, sizeof(buf), portMAX_DELAY);
        if (n > 0) {
            pk_line_feed(&s_line, buf, (size_t)n, dispatch_line, NULL);
        }
    }
}

esp_err_t pk_usb_start(pk_usb_line_cb_t on_line)
{
    s_on_line = on_line;
    pk_line_init(&s_line);

    usb_serial_jtag_driver_config_t config = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
    // 默认各 256 字节。启动日志突发时加大发送缓冲,减少按键帧被挤掉的概率。
    config.tx_buffer_size = 1024;
    config.rx_buffer_size = 512;
    ESP_RETURN_ON_ERROR(usb_serial_jtag_driver_install(&config), TAG, "driver install failed");
    usb_serial_jtag_vfs_use_driver();

    BaseType_t ok = xTaskCreate(rx_task, "pk_usb_rx", RX_TASK_STACK, NULL, RX_TASK_PRIO, NULL);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "rx task create failed");
    return ESP_OK;
}

void pk_usb_send(const char *data, size_t len)
{
    if (len == 0 || !usb_serial_jtag_is_connected()) return;
    // 直接写 stdout 的 fd:一次 VFS write 在写锁内完成整帧,并绕过 FILE 缓冲立即进入驱动发送队列。
    ssize_t written = write(fileno(stdout), data, len);
    (void)written;
}

bool pk_usb_host_present(void)
{
    return usb_serial_jtag_is_connected();
}
