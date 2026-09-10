# Passport Keys 通信协议 v1

Passport 固件与 macOS app 之间使用 **JSON Lines**:每条消息是一行 UTF-8 JSON 对象,以 `\n` 结尾。USB 与 BLE 两种链路使用完全相同的消息。

## 链路

| 链路 | 设备侧 | Mac 侧 | 说明 |
| --- | --- | --- | --- |
| USB | ESP32-C3 原生 USB Serial/JTAG(CDC) | `/dev/cu.usbmodem*`,USB VID `0x303A` | 与 ESP-IDF 日志共用通道,Mac 从行内 `{"t":` 处开始解析,其余内容忽略 |
| BLE | NimBLE GATT 外设,广播名 `Passport Keys` | CoreBluetooth central | 无配对;一次写入/通知可能只包含半行,两端都按 `\n` 重新组帧 |

BLE GATT:

| 项 | UUID | 属性 |
| --- | --- | --- |
| Service | `12D4FA08-7418-48FA-A95A-B43A2E669E55` | Primary,UUID 放在广播包里 |
| Events(设备 → Mac) | `12D4FA09-7418-48FA-A95A-B43A2E669E55` | Notify |
| Commands(Mac → 设备) | `12D4FA0A-7418-48FA-A95A-B43A2E669E55` | Write / Write Without Response |

Mac 端策略:USB 优先。检测到已刷入本固件的 USB 设备时断开蓝牙;USB 断开后自动回到蓝牙扫描。

## 设备 → Mac

| 类型 | 示例 | 触发时机 |
| --- | --- | --- |
| hello | `{"t":"hello","fw":"passport-keys","proto":1,"ver":"1.0.0","boot":"9f3a21c4"}` | 收到 `hello` 命令 |
| btn | `{"t":"btn","k":"up","e":"press","seq":12,"boot":"9f3a21c4"}` | 按键按下瞬间 |
| bat | `{"t":"bat","soc":87,"mv":4012}` | `hello` 之后,以及每 60 秒;读不到时为 `-1` |
| pong | `{"t":"pong"}` | 收到 `ping` |
| ack | `{"t":"ack","cmd":"labels"}` | 收到 `labels` |

- `ver`:固件版本,取自构建时写入的 ESP-IDF 应用描述。发布版为 `X.Y.Z`,本地构建为 `git describe` 的结果;app 只用于显示。
- `k`:`up` / `down` / `ok`。
- `e`:v1 只发送 `press`。
- `seq`:本次上电后单调递增;`boot` 是每次上电随机生成的 8 位十六进制。Mac 用 `(boot, seq)` 去重,避免双链路或重传导致重复触发。

## Mac → 设备

| 命令 | 示例 | 设备行为 |
| --- | --- | --- |
| hello | `{"cmd":"hello"}` | 回复 `hello` 与 `bat`,并把该链路标记为"已连接 app" |
| ping | `{"cmd":"ping"}` | 回复 `pong`;Mac 每 5 秒发送一次,设备 15 秒收不到命令即认为 app 已离线;USB 拔线时立即离线 |
| labels | `{"cmd":"labels","down":"Down","ok":"Return","up":"Cmd+A"}` | 在屏幕上显示每个键当前映射的快捷键(ASCII,最长 31 字节) |
| bye | `{"cmd":"bye"}` | app 退出前发送,设备立即显示离线 |

设备只解析扁平对象中的字符串字段;未知字段忽略,未知命令丢弃。单行最长 255 字节,超长行整行丢弃。
