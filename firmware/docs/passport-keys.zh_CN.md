<p align="right">
  <strong>简体中文</strong> | <a href="passport-keys.md">English</a>
</p>

# Passport Keys 固件

Passport Keys 用单一用途的应用替换了上游的演示菜单:上、下、确认三个按键被转发给 macOS 上的 Passport Keys app,由 app 把每次按键变成用户设定的快捷键,例如 ⌘A。

ESP32-C3 没有 USB OTG 控制器,无法枚举成 USB 键盘。因此固件通过原生 USB Serial/JTAG 串口或低功耗蓝牙发送按键事件,由 macOS app 合成键盘事件。

## 行为

| 方面 | 行为 |
| --- | --- |
| 按键 | 按下瞬间(`BSP_BTN_PRESS`)发送一条 `btn` 消息。单击、双击、长按事件忽略,一次物理按压只触发一次快捷键。 |
| USB 链路 | 安装 USB Serial/JTAG 驱动并让控制台走驱动。协议帧与 ESP-IDF 日志共用端口;macOS app 从 `{"t":` 处开始解析,忽略其它文本。 |
| BLE 链路 | 可连接的 NimBLE 外设,名称 `Passport Keys`,单连接、无配对。事件走 Notify 特征,命令走 Write Without Response。按 Apple 配件设计指南,开机、断开或 USB 拔线后以 20 ms 间隔广播 30 秒,之后改为 211.25 ms。 |
| 屏幕 | 显示连接状态、每个键当前映射的快捷键(由 macOS app 下发)和电量。按下的行会高亮,吉祥物跳一下。 |
| 背光 | 活动时 80%,空闲超过 macOS app 中设置的时间后熄灭(默认 10 秒,设为 `0` 永不熄屏)。按键、连接变化或收到新设置时点亮;唤醒屏幕的那次按键照常转发。 |
| 电量 | 每 60 秒读取一次并发给已连接的 app;CW2017 不可用时上报 `-1`。 |
| 故障 | 屏幕初始化失败时以无屏模式继续运行;单条链路启动失败只记录日志,另一条链路照常工作;不会自动擦除 NVS。 |

## 协议摘要

每条消息是一行 UTF-8 JSON 对象,以 `\n` 结尾;两条链路传输相同的消息。

| 方向 | 消息 | 示例 |
| --- | --- | --- |
| 设备到 Mac | hello | `{"t":"hello","fw":"passport-keys","proto":1,"ver":"1.0.0","boot":"9f3a21c4"}` |
| 设备到 Mac | 按键 | `{"t":"btn","k":"up","e":"press","seq":12,"boot":"9f3a21c4"}` |
| 设备到 Mac | 电量 | `{"t":"bat","soc":87,"mv":4012}` |
| 设备到 Mac | pong / ack | `{"t":"pong"}`、`{"t":"ack","cmd":"labels"}` |
| Mac 到设备 | hello / ping / bye | `{"cmd":"hello"}` |
| Mac 到设备 | labels | `{"cmd":"labels","down":"Down","ok":"Return","up":"Cmd+A"}` |
| Mac 到设备 | config | `{"cmd":"config","screen_off":10}` |

Mac 每 5 秒发送一次 ping。设备在 15 秒收不到命令、收到 `bye`、BLE 断开或 USB 拔线时认为链路离线。`(boot, seq)` 供 Mac 丢弃重复的按键。`config` 下发的息屏时间只保存在内存里,设备重启后在 app 重新连接前使用默认的 10 秒。

| BLE 项 | UUID |
| --- | --- |
| Service | `12D4FA08-7418-48FA-A95A-B43A2E669E55` |
| Events(Notify) | `12D4FA09-7418-48FA-A95A-B43A2E669E55` |
| Commands(Write) | `12D4FA0A-7418-48FA-A95A-B43A2E669E55` |

## 源码结构

| 文件 | 职责 |
| --- | --- |
| `main/main.c` | 板级初始化顺序与启动降级 |
| `main/pk_app.c` | 事件队列、唯一的消费任务、链路存活判断、电量与背光 |
| `main/pk_protocol.c` | 纯 C 的消息格式化、命令解析与行组帧,由 `tests/test_pk_protocol.c` 覆盖 |
| `main/pk_usb.c` | USB Serial/JTAG 驱动、接收任务与帧输出 |
| `main/pk_ble.c` | NimBLE GATT 服务、广播、连接参数与通知 |
| `main/pk_ui.c` | 使用 `ui_pixel` 主题的 LVGL 主屏 |

## 编译与烧录

```bash
source <path-to-esp-idf-v5.5.3>/export.sh
./tools/validate.sh --static
idf.py build
idf.py -p <port> flash
```

烧录前请退出 macOS app,因为它会独占串口。`idf.py flash` 分别写入 bootloader、分区表和应用,不会写受保护的 `cardid` 分区。

`hello` 消息里的 `ver` 取自 ESP-IDF 应用描述:发布构建通过 `PROJECT_VER` 指定(例如 `PROJECT_VER=1.2.3 ./tools/validate.sh --firmware`),本地构建使用 `git describe` 的结果。正式版本由仓库根目录的 Publish 工作流发布,见 [release.md](../../docs/release.md)。

## 真机验收

- 启动后屏幕显示 `WAITING FOR MAC`,三行显示 `--`,有电量计时显示电量。
- 运行 macOS app 并用 USB 数据线连接后,约 2 秒内状态变为 `USB CONNECTED`,每行显示映射的快捷键。
- 断开 USB 且 Mac 开启蓝牙时,状态在约 2 秒内变为 `BLE CONNECTED`。
- 每按一次键,对应行高亮一次,Mac 执行一次映射的快捷键。
- 退出 app 或拔掉 USB 后,状态在 1 秒内回到 `WAITING FOR MAC`;Mac 切换到蓝牙后显示 `BLE CONNECTED`。蓝牙断开按 4 秒监督超时检测,app 停止响应时 15 秒后判定离线。
- 默认设置下空闲 10 秒熄屏,按键后恢复;在 macOS app 中设为 0 后屏幕常亮。
