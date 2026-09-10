# 持续集成与发布

发布流程参照 [oomol-lab/oo-cli](https://github.com/oomol-lab/oo-cli):代码里不手动维护版本号,由 GitHub Actions 的 Publish 工作流根据已有的 tag 计算版本,并行构建 macOS app 与固件,最后创建 GitHub Release 并自动生成更新说明。

## Pull Request 检查

每个 Pull Request 都会运行 `.github/workflows/pr-check.yaml`:

| Job | 运行环境 | 内容 |
| --- | --- | --- |
| Static checks | ubuntu-latest | 固件仓库检查、actionlint、固件主机测试(`firmware/tools/validate.sh --static`),以及 `contrib/ci` 发布脚本的单元测试 |
| macOS app | macos-26(Xcode 26) | XcodeGen 生成工程,运行单元测试,再以 ad-hoc 签名编译 Release |
| Firmware | ubuntu-latest,ESP-IDF v5.5.3 Docker 镜像 | 编译固件、合并镜像并校验受保护分区(`firmware/tools/validate.sh --firmware`),合并镜像作为 artifact 保留 7 天 |

## 发布新版本

1. 确认要发布的改动已经合入 `main`,且 PR Check 全部通过。
2. 打开仓库的 Actions,选择 Publish,点击 Run workflow,分支选 `main`。
3. 填写参数后运行:

| 参数 | 说明 |
| --- | --- |
| `expected_version` | 指定版本号,格式为 `X.Y.Z`,可以带 `v` 前缀。留空时按 `version_bump` 在最新的正式版 tag 上递增 |
| `version_bump` | `patch`、`minor` 或 `major`,只在 `expected_version` 为空时生效 |

版本规则:

- 只识别 `vX.Y.Z` 形式的正式版 tag,`v2.0.0-beta.1` 这类预发布 tag 会被忽略。
- 仓库还没有正式版 tag 时,从 `0.0.0` 开始递增,例如 `patch` 得到 `0.0.1`。
- 目标 tag 已经存在时工作流直接失败,不会覆盖已发布的版本。
- Release 由 `gh release create` 创建:tag 指向触发时的提交,标题为 tag 名,更新说明从上一个正式版 tag 开始自动生成,并标记为 Latest。重新运行同一次发布时,只会用 `--clobber` 覆盖上传产物。

Publish 工作流包含 4 个 job:

| Job | 内容 |
| --- | --- |
| compute-version | `contrib/ci/release_version.py` 读取 tag,输出 `version`、`tag_name`、`previous_tag` |
| build-macos | `macos/scripts/release.sh`:注入版本号与构建号编译 Release,按 secrets 决定是否用 Developer ID 签名并公证,打包 zip |
| build-firmware | 以 `PROJECT_VER=<version>` 运行 `firmware/tools/validate.sh --firmware`,校验镜像里的版本号与受保护分区,输出合并镜像 |
| publish | 下载两个构建产物,生成 `SHA256SUMS`,由 `contrib/ci/github_release.py` 创建 Release 或向已有 Release 上传产物 |

## 发布产物

| 文件 | 说明 |
| --- | --- |
| `PassportKeys-<version>-macOS.zip` | macOS app。`CFBundleShortVersionString` 为发布版本,`CFBundleVersion` 为 Publish 工作流的运行编号 |
| `passport-keys-firmware-<version>.bin` | 从地址 `0x0` 写入的合并固件镜像(bootloader、分区表、应用)。固件 `hello` 消息里的 `ver` 就是发布版本,app 设置页的"固件版本"会显示它 |
| `SHA256SUMS` | 以上两个文件的 SHA-256 |

## 签名与公证

在仓库的 Settings > Secrets and variables > Actions 中配置以下 secrets。5 项全部配置时,app 用 Developer ID 签名、提交 Apple 公证并装订票据;全部不配置时改为 ad-hoc 签名;只配置一部分时工作流报错,避免误发未公证的版本。签名结果会写在 build-macos job 的 Summary 里。

| Secret | 内容 |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | Developer ID Application 证书与私钥导出的 `.p12` 文件,base64 编码 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `APP_STORE_CONNECT_API_KEY_P8_BASE64` | App Store Connect API 密钥 `.p8` 文件,base64 编码 |
| `APP_STORE_CONNECT_API_KEY_ID` | API 密钥 ID |
| `APP_STORE_CONNECT_API_ISSUER_ID` | API 密钥的 Issuer ID |

获取方式:

1. 在 Apple Developer 网站的 Certificates, Identifiers & Profiles 中创建 Developer ID Application 证书并安装到钥匙串。在"钥匙串访问"里同时选中证书和对应的私钥,导出为 `.p12` 并设置密码。
2. 在 App Store Connect 的"用户和访问 > 集成 > App Store Connect API"中创建团队密钥,访问权限选 Developer。下载 `.p8`(只能下载一次),记下密钥 ID 和页面上的 Issuer ID。
3. 用 GitHub CLI 写入 secrets,避免把内容粘贴到网页或命令历史里:

```bash
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERTIFICATE_P12_BASE64
gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD   # 按提示输入密码
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set APP_STORE_CONNECT_API_KEY_P8_BASE64
gh secret set APP_STORE_CONNECT_API_KEY_ID        # 按提示输入密钥 ID
gh secret set APP_STORE_CONNECT_API_ISSUER_ID     # 按提示输入 Issuer ID
```

写入后删除本地导出的 `.p12`,并妥善保管 `.p8`。

### 未签名版本对用户的影响

没有配置上述 secrets 时,Release 里的 app 只有 ad-hoc 签名,也没有经过公证:

- 下载后第一次打开会被 Gatekeeper 拦截。用户需要在 系统设置 > 隐私与安全性 页面底部点"仍要打开",或者执行 `xattr -dr com.apple.quarantine /Applications/PassportKeys.app`。
- 系统按代码签名识别辅助功能与蓝牙授权,而 ad-hoc 签名每次构建都不同。每次更新 app 后,用户需要在 系统设置 > 隐私与安全性 > 辅助功能 中删除旧的 Passport Keys 条目并重新添加,否则按键映射不会生效。

Developer ID 签名并公证的版本没有这两个问题。

## 刷写发布版固件

CI 在发布前已经校验过固件镜像:

- 分区表里 `factory` 应用分区与受保护的 `cardid` 分区的位置和大小没有变化;
- 镜像结束于 `cardid` 的起始地址 `0x356000` 之前,从 `0x0` 写入不会擦除设备身份数据;
- 应用描述里的版本号等于发布版本。

刷写步骤(需要 esptool:ESP-IDF 环境自带,也可以 `pip install esptool`):

1. 从菜单栏退出 Passport Keys app,释放串口。
2. 校验下载的文件:

   ```bash
   shasum -a 256 -c SHA256SUMS --ignore-missing
   ```

3. 第一次刷写某台设备前,备份整片 8 MB Flash。备份含设备身份数据,不要上传或分享:

   ```bash
   python -m esptool --chip esp32c3 -p /dev/cu.usbmodemXXXX read_flash 0 0x800000 passport-backup.bin
   ```

4. 只写入发布的镜像:

   ```bash
   python -m esptool --chip esp32c3 -p /dev/cu.usbmodemXXXX write_flash 0x0 passport-keys-firmware-<version>.bin
   ```

禁止事项:

- 不要执行 `idf.py erase-flash` 或 `esptool erase_flash`,也不要给 `write_flash` 加 `--erase-all`。它们会清掉 `cardid` 分区里的设备身份数据,无法恢复。
- 不要把来源不明或体积超过 `0x356000` 的整片镜像写到 `0x0`。

从源码烧录时使用 `scripts/flash-firmware.sh`,它会自动备份并分段烧录。

## 本地演练

```bash
# 发布脚本单元测试
python3 -m unittest discover --start-directory contrib/ci --pattern "test_*.py"

# 计算版本号;不设置 GITHUB_OUTPUT 时输出 JSON
VERSION_BUMP=patch python3 contrib/ci/release_version.py

# 打包 app;不设置签名变量时为 ad-hoc 签名,产物在 macos/build/release
VERSION=1.2.3 BUILD_NUMBER=1 macos/scripts/release.sh

# 编译并校验带版本号的固件,产物在 firmware/build/FoloToy-AI-Passport-full.bin
source ~/esp/esp-idf-v5.5.3/export.sh
cd firmware && PROJECT_VER=1.2.3 ./tools/validate.sh --firmware
```
