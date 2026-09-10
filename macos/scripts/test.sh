#!/usr/bin/env bash
# 运行 Mac app 单元测试(协议解析、行组帧、去重、快捷键格式化、设置持久化)。
#   SIGN_IDENTITY=- ./scripts/test.sh     没有开发证书时改用 ad-hoc 签名(CI 使用)
#   BUILD_DIR=/tmp/pk ./scripts/test.sh   改变 DerivedData 所在目录(默认 build)
set -euo pipefail

cd "$(dirname "$0")/.."
build_dir="${BUILD_DIR:-build}"

xcodegen generate --quiet

signing_args=()
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    signing_args=(CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" DEVELOPMENT_TEAM="")
fi

xcodebuild \
    -project PassportKeys.xcodeproj \
    -scheme PassportKeys \
    -derivedDataPath "${build_dir}/DerivedData" \
    -destination 'platform=macOS' \
    ${signing_args[@]+"${signing_args[@]}"} \
    test
