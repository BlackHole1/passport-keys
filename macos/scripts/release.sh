#!/usr/bin/env bash
# 发布打包:编译 Release,按需用 Developer ID 签名并公证,输出 zip。
#   VERSION=1.2.3 BUILD_NUMBER=42 ./scripts/release.sh
# 产物:$BUILD_DIR/release/PassportKeys-<version>-macOS.zip(BUILD_DIR 默认 build)。
#
# 以下 5 个变量全部设置时签名并公证;全部不设置时为 ad-hoc 签名;只设置一部分视为配置错误。
#   DEVELOPER_ID_CERTIFICATE_P12_BASE64   Developer ID Application 证书与私钥(.p12)的 base64
#   DEVELOPER_ID_CERTIFICATE_PASSWORD     导出 .p12 时设置的密码
#   APP_STORE_CONNECT_API_KEY_P8_BASE64   App Store Connect API 密钥(.p8)的 base64
#   APP_STORE_CONNECT_API_KEY_ID          密钥 ID
#   APP_STORE_CONNECT_API_ISSUER_ID       Issuer ID
set -euo pipefail

cd "$(dirname "$0")/.."

: "${VERSION:?需要 VERSION,例如 VERSION=1.2.3}"
build_dir="${BUILD_DIR:-build}"
release_dir="${build_dir}/release"
app="${build_dir}/PassportKeys.app"
archive="${release_dir}/PassportKeys-${VERSION}-macOS.zip"

signing_vars=(
    DEVELOPER_ID_CERTIFICATE_P12_BASE64
    DEVELOPER_ID_CERTIFICATE_PASSWORD
    APP_STORE_CONNECT_API_KEY_P8_BASE64
    APP_STORE_CONNECT_API_KEY_ID
    APP_STORE_CONNECT_API_ISSUER_ID
)
configured=0
for name in "${signing_vars[@]}"; do
    if [[ -n "${!name:-}" ]]; then
        configured=$((configured + 1))
    fi
done
if (( configured != 0 && configured != ${#signing_vars[@]} )); then
    echo "ERROR: Developer ID 签名需要同时设置 ${signing_vars[*]}" >&2
    exit 1
fi
developer_id=false
if (( configured == ${#signing_vars[@]} )); then
    developer_id=true
fi

report() {
    echo "$1"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        echo "$1" >> "${GITHUB_STEP_SUMMARY}"
    fi
}

SIGN_IDENTITY=- CONFIGURATION=Release BUILD_DIR="${build_dir}" ./scripts/build.sh

work_dir="$(mktemp -d)"
keychain="${work_dir}/signing.keychain-db"
cleanup() {
    if [[ -f "${keychain}" ]]; then
        security delete-keychain "${keychain}" >/dev/null 2>&1 || true
    fi
    rm -rf "${work_dir}"
}
trap cleanup EXIT

if [[ "${developer_id}" == true ]]; then
    printf '%s' "${DEVELOPER_ID_CERTIFICATE_P12_BASE64}" | base64 --decode > "${work_dir}/certificate.p12"
    printf '%s' "${APP_STORE_CONNECT_API_KEY_P8_BASE64}" | base64 --decode > "${work_dir}/api-key.p8"

    # 证书导入临时钥匙串,并放到搜索列表最前面,codesign 才能找到身份。
    keychain_password="$(uuidgen)"
    security create-keychain -p "${keychain_password}" "${keychain}"
    security set-keychain-settings -lut 21600 "${keychain}"
    security unlock-keychain -p "${keychain_password}" "${keychain}"
    security import "${work_dir}/certificate.p12" -k "${keychain}" \
        -P "${DEVELOPER_ID_CERTIFICATE_PASSWORD}" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
        -k "${keychain_password}" "${keychain}" >/dev/null
    search_list=()
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line#\"}"
        search_list+=("${line%\"}")
    done < <(security list-keychains -d user)
    security list-keychains -d user -s "${keychain}" ${search_list[@]+"${search_list[@]}"}

    identity="$(security find-identity -v -p codesigning "${keychain}" \
        | awk '/"Developer ID Application/ { print $2; exit }')"
    if [[ -z "${identity}" ]]; then
        echo "ERROR: 证书中没有 Developer ID Application 身份" >&2
        exit 1
    fi
    sign_args=(--sign "${identity}" --timestamp)
else
    sign_args=(--sign -)
fi

# 统一重新签名:去掉 Xcode 为 ad-hoc 签名注入的 get-task-allow(公证会拒绝),保留 hardened runtime。
# app 没有嵌套的 framework,对整个 bundle 签名即可。
codesign --force --options runtime "${sign_args[@]}" "${app}"
codesign --verify --strict --verbose=2 "${app}"

if [[ "${developer_id}" == true ]]; then
    notary_auth=(
        --key "${work_dir}/api-key.p8"
        --key-id "${APP_STORE_CONNECT_API_KEY_ID}"
        --issuer "${APP_STORE_CONNECT_API_ISSUER_ID}"
    )
    ditto -c -k --keepParent "${app}" "${work_dir}/notarize.zip"
    submission="$(xcrun notarytool submit "${work_dir}/notarize.zip" "${notary_auth[@]}" \
        --wait --output-format json)"
    status="$(python3 -c 'import json, sys; print(json.load(sys.stdin).get("status", ""))' <<< "${submission}")"
    if [[ "${status}" != "Accepted" ]]; then
        echo "ERROR: 公证结果为 ${status:-unknown}" >&2
        submission_id="$(python3 -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))' <<< "${submission}")"
        if [[ -n "${submission_id}" ]]; then
            xcrun notarytool log "${submission_id}" "${notary_auth[@]}" >&2 || true
        fi
        exit 1
    fi
    xcrun stapler staple "${app}"
    spctl --assess --type execute --verbose=2 "${app}"
    signing="Developer ID 签名,已公证"
else
    signing="ad-hoc 签名,未公证(没有配置 Developer ID secrets,用户首次打开需要在系统设置中放行,更新后需要重新授予辅助功能权限)"
fi

mkdir -p "${release_dir}"
rm -f "${archive}"
ditto -c -k --keepParent "${app}" "${archive}"

report "### PassportKeys ${VERSION}"
report ""
report "- 构建号:${BUILD_NUMBER:-project.yml 默认值}"
report "- 签名:${signing}"
report "- 产物:$(basename "${archive}")"
