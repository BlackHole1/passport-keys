#!/usr/bin/env bash
# 生成 Xcode 工程并编译 app,产物复制到 macos/build/PassportKeys.app。
#   CONFIGURATION=Debug ./scripts/build.sh   编译 Debug(默认 Release)
#   SIGN_IDENTITY=- ./scripts/build.sh        没有开发证书时改用 ad-hoc 签名
#                                             (每次重新编译后需要重新授予辅助功能权限)
#   VERSION=1.2.3 BUILD_NUMBER=42 ./scripts/build.sh
#                                             覆盖 project.yml 里的版本号与构建号(发布流程使用)
#   BUILD_DIR=/tmp/pk ./scripts/build.sh      改变 DerivedData 与产物所在目录(默认 build)
set -euo pipefail

cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-Release}"
build_dir="${BUILD_DIR:-build}"
derived_data="${build_dir}/DerivedData"

xcodegen generate --quiet

build_settings=()
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    build_settings+=(CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" DEVELOPMENT_TEAM="")
fi
if [[ -n "${VERSION:-}" ]]; then
    build_settings+=(MARKETING_VERSION="${VERSION}")
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    build_settings+=(CURRENT_PROJECT_VERSION="${BUILD_NUMBER}")
fi

xcodebuild \
    -project PassportKeys.xcodeproj \
    -scheme PassportKeys \
    -configuration "${configuration}" \
    -derivedDataPath "${derived_data}" \
    -destination 'platform=macOS' \
    ${build_settings[@]+"${build_settings[@]}"} \
    build

mkdir -p "${build_dir}"
rm -rf "${build_dir}/PassportKeys.app"
cp -R "${derived_data}/Build/Products/${configuration}/PassportKeys.app" "${build_dir}/PassportKeys.app"
echo "Built $(cd "${build_dir}" && pwd)/PassportKeys.app"
