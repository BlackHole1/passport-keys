<p align="right">
  <a href="passport-keys.zh_CN.md">简体中文</a> | <strong>English</strong>
</p>

# Passport Keys Firmware

Passport Keys replaces the upstream demo menu with a single-purpose application. The UP, DOWN, and OK buttons are forwarded to the Passport Keys macOS app, which turns each press into a user-defined keyboard shortcut such as Command-A.

The ESP32-C3 has no USB OTG controller, so the board cannot enumerate as a USB keyboard. The firmware instead sends button events over the native USB Serial/JTAG port or Bluetooth LE, and the macOS app synthesizes the keystrokes.

## Behavior

| Area | Behavior |
| --- | --- |
| Buttons | The press edge (`BSP_BTN_PRESS`) sends one `btn` message. Click, double-click, and long-press events are ignored, so one physical press produces exactly one shortcut. |
| USB link | Installs the USB Serial/JTAG driver and routes the console through it. Protocol frames share the port with ESP-IDF logs; the macOS app parses from `{"t":` and ignores other text. |
| BLE link | Connectable NimBLE peripheral named `Passport Keys`, one connection, no pairing. Events use a Notify characteristic; commands use Write Without Response. Following Apple's accessory design guidelines, it advertises every 20 ms for 30 seconds after boot, a disconnect, or USB being unplugged, then every 211.25 ms. |
| Screen | Shows the link state, the shortcut mapped to each button (sent by the macOS app), and the battery level. The pressed row flashes and the mascot jumps. |
| Backlight | 80% when active, off after the idle timeout set in the macOS app (10 seconds by default, `0` keeps the screen on). A button press, link change, or new setting wakes it; the waking press is still forwarded. |
| Battery | Read every 60 seconds and sent to connected apps. `-1` is reported when the CW2017 gauge is unavailable. |
| Failures | A display failure keeps the firmware running without a screen. A failure of one link is logged and the other link keeps working. NVS is never erased automatically. |

## Protocol summary

Each message is one UTF-8 JSON object followed by `\n`. Both links carry the same messages.

| Direction | Message | Example |
| --- | --- | --- |
| Device to Mac | hello | `{"t":"hello","fw":"passport-keys","proto":1,"ver":"1.0.0","boot":"9f3a21c4"}` |
| Device to Mac | button | `{"t":"btn","k":"up","e":"press","seq":12,"boot":"9f3a21c4"}` |
| Device to Mac | battery | `{"t":"bat","soc":87,"mv":4012}` |
| Device to Mac | pong / ack | `{"t":"pong"}`, `{"t":"ack","cmd":"labels"}` |
| Mac to device | hello / ping / bye | `{"cmd":"hello"}` |
| Mac to device | labels | `{"cmd":"labels","down":"Down","ok":"Return","up":"Cmd+A"}` |
| Mac to device | config | `{"cmd":"config","screen_off":10}` |

The Mac pings every 5 seconds. The device treats a link as offline after 15 seconds without a command, or immediately after `bye`, a BLE disconnect, or the USB cable being unplugged. `(boot, seq)` lets the Mac drop duplicate presses. The screen-off timeout from `config` is kept in RAM only, so after a reboot the device uses 10 seconds until the app connects again.

| BLE item | UUID |
| --- | --- |
| Service | `12D4FA08-7418-48FA-A95A-B43A2E669E55` |
| Events (Notify) | `12D4FA09-7418-48FA-A95A-B43A2E669E55` |
| Commands (Write) | `12D4FA0A-7418-48FA-A95A-B43A2E669E55` |

## Source layout

| File | Responsibility |
| --- | --- |
| `main/main.c` | Board initialization order and startup degradation |
| `main/pk_app.c` | Event queue, the only consumer task, link liveness, battery, and backlight |
| `main/pk_protocol.c` | Pure C message formatting, command parsing, and line framing; covered by `tests/test_pk_protocol.c` |
| `main/pk_usb.c` | USB Serial/JTAG driver, receive task, and frame output |
| `main/pk_ble.c` | NimBLE GATT service, advertising, connection parameters, and notifications |
| `main/pk_ui.c` | LVGL screen built with the `ui_pixel` theme |

## Build and flash

```bash
source <path-to-esp-idf-v5.5.3>/export.sh
./tools/validate.sh --static
idf.py build
idf.py -p <port> flash
```

Quit the macOS app before flashing because it opens the serial port exclusively. `idf.py flash` writes the bootloader, partition table, and application separately and does not touch the protected `cardid` partition.

The `ver` field in `hello` is the ESP-IDF app description version. Release builds set it with `PROJECT_VER` (for example `PROJECT_VER=1.2.3 ./tools/validate.sh --firmware`); local builds use `git describe`. Releases are published by the repository root Publish workflow, described in [release.md](../../docs/release.md).

## Device acceptance

- After boot, the screen shows `WAITING FOR MAC`, three rows showing `--`, and the battery level when the gauge is present.
- With the macOS app running and a USB data cable connected, the status changes to `USB CONNECTED` within about 2 seconds and each row shows the mapped shortcut.
- With USB disconnected and Bluetooth enabled on the Mac, the status changes to `BLE CONNECTED` within about 2 seconds.
- Each button press flashes its row once and the Mac performs the mapped shortcut exactly once.
- Quitting the app or unplugging USB returns the status to `WAITING FOR MAC` within a second, or to `BLE CONNECTED` once the Mac switches to Bluetooth. A lost BLE link is detected by the 4-second supervision timeout, and an app that stops responding is dropped after 15 seconds.
- With the default setting the backlight turns off after 10 seconds idle and a button press restores it. Setting the timeout to 0 in the macOS app keeps the screen on.
