// main/pk_usb.h: USB Serial/JTAG 链路:与 ESP-IDF 控制台共用 ESP32-C3 原生 USB。
#pragma once

#include "esp_err.h"

#include <stdbool.h>
#include <stddef.h>

// 每收到完整一行调用一次,运行在 USB 接收任务中,必须快速返回。
typedef void (*pk_usb_line_cb_t)(const char *line, size_t len);

// 安装 USB Serial/JTAG 驱动,把控制台切换到驱动模式,并启动接收任务。
esp_err_t pk_usb_start(pk_usb_line_cb_t on_line);

// 发送一帧(完整一行)。没有接主机时直接丢弃;主机未读取时由驱动在约 50 ms 内超时丢弃,不会长期阻塞。
void pk_usb_send(const char *data, size_t len);

// 是否有 USB 主机在轮询本设备(按 SOF 判断)。拔线或主机休眠后几毫秒内变为 false。可从任意任务调用。
bool pk_usb_host_present(void);
