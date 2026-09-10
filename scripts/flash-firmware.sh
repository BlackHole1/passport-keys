#!/usr/bin/env bash
# 编译并烧录 Passport Keys 固件到通过 USB 连接的 FoloToy AI Passport。
#
# - 第一次给某台设备烧录前,把整片 8 MB Flash 备份到 ~/esp/passport-backups/,可用于恢复原固件。
#   备份里含设备身份数据(cardid 分区),不要上传或分享。
# - 使用 idf.py 分段烧录(bootloader、分区表、应用),不擦除整片 Flash,不写受保护的 cardid 分区。
#
# 可选环境变量:
#   PORT=/dev/cu.usbmodemXXXX   指定串口(默认取第一个 /dev/cu.usbmodem*)
#   IDF_EXPORT=...              ESP-IDF v5.5.3 的 export.sh(默认 ~/esp/esp-idf-v5.5.3/export.sh)
#   BACKUP_DIR=...              备份目录(默认 ~/esp/passport-backups)
#   SKIP_BACKUP=1               跳过备份
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
idf_export="${IDF_EXPORT:-${HOME}/esp/esp-idf-v5.5.3/export.sh}"
backup_dir="${BACKUP_DIR:-${HOME}/esp/passport-backups}"

if pgrep -xq PassportKeys; then
    echo "Passport Keys app 正在独占串口,请先从菜单栏退出 app 再烧录。" >&2
    exit 1
fi

port="${PORT:-}"
if [[ -z "${port}" ]]; then
    port="$(ls /dev/cu.usbmodem* 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "${port}" ]]; then
    echo "没有找到 USB 串口。请打开 Passport 电源(长按电源键 0.5 秒),并用支持数据传输的 USB-C 线连接 Mac。" >&2
    exit 1
fi

if [[ ! -f "${idf_export}" ]]; then
    echo "找不到 ${idf_export},请先安装 ESP-IDF v5.5.3(见 firmware/docs/development/engineering/environment-setup.md)。" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "${idf_export}" >/dev/null
if ! idf.py --version | grep -q "v5.5.3"; then
    echo "需要 ESP-IDF v5.5.3,当前为 $(idf.py --version)。" >&2
    exit 1
fi

cd "${root}/firmware"
idf.py build

if [[ "${SKIP_BACKUP:-0}" != "1" ]]; then
    mac="$(python -m esptool --chip esp32c3 -p "${port}" read_mac | awk '/^MAC:/ { print $2; exit }' | tr -d ':')"
    if [[ -z "${mac}" ]]; then
        echo "读取设备 MAC 失败,已停止烧录。" >&2
        exit 1
    fi
    backup="${backup_dir}/passport-${mac}-flash.bin"
    if [[ -f "${backup}" ]]; then
        echo "已有备份 ${backup},跳过备份。"
    else
        mkdir -p "${backup_dir}"
        python -m esptool --chip esp32c3 -p "${port}" -b 460800 read_flash 0 0x800000 "${backup}.partial"
        mv "${backup}.partial" "${backup}"
        echo "已备份整片 Flash:${backup}"
    fi
fi

idf.py -p "${port}" flash
echo "烧录完成,设备已重启进入 Passport Keys。"
