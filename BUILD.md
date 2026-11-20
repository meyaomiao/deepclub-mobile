# 构建与源码 / Build and source

## 固定输入

- Flutter 3.47.7 / Dart 3.13.5，JDK 17，Android SDK 36、NDK 28.2.13676358。
- Python 3.12+；Node.js 24 用于运行时与 helper 测试。
- 原始源码和 runtime APK 的版本、长度与 SHA-256 位于 [upstream.lock.json](upstream.lock.json)。
- 运行时原始下载：[GitHub v1.0.15 arm64 APK](https://github.com/ccch1mneyyy/dsh-Go/releases/download/v1.0.15/dsh-go-1.0.15-arm64.apk)；上游公开镜像 URL 也记录在 lock 中。下载后必须通过脚本摘要校验，不信任文件名。

## 准备源码

```sh
python3 scripts/prepare.py --checkout .work/dsh-go
```

该命令固定检出上游提交、预检文本补丁、核对原资产摘要，再应用自有替换和新增源码。已有 dirty 或不匹配提交的目录会被拒绝，不执行 reset/stash。重新验证时使用新的目录。

在准备树的 `app/` 中，使用原始依赖锁和 pub.dev 源：

```sh
flutter pub get --enforce-lockfile
python3 tool/l10n_merge.py
python3 tool/l10n_merge.py --check
flutter analyze --no-pub
flutter test --no-pub test/deepclub test/deepclub_surface test/brand/site_update_test.dart
```

主机行为测试不依赖 Linux 金图字体。上游原品牌、退休功能和金图测试仍属于原产品矩阵，不用本首版的通过记录替代它们。新增 Kotlin cleanup/ownership/launch-guard 与 GuestSetup 的测试按验证记录独立编译执行；完整 Gradle 单测源集仍包含引用已排除 phone 实现的历史测试，不宣称全量通过。

## 准备运行时

```sh
python3 scripts/prepare-runtime.py --checkout .work/dsh-go --apk /absolute/path/dsh-go-1.0.15-arm64.apk
```

脚本只导入固定 APK 的 Linux runtime、许可证和声明的 Termux 库，不导入原 DEX/Flutter 资产。它把 `runtime/deepclub-tools` 放进 `/opt/dsh-go`，保留运行时升级的路径边界；构建配方、插件源和 lock 都纳入运行时版本摘要。

standard/ptc/cordis 中的内置搜索配置按精确 SHA 和唯一块替换，保留网页读取。`deepclub-tools` 的插件入口不放在 CLI overlay：原生启动前 helper 幂等写入可配置的 web profile，保留已有用户设置。

验证命令从准备树根目录执行：

```sh
python3 tooling/check_runtime_bundle.py arm64
```

## 签名与 APK

在仓库外保存自己的签名材料，并在准备树的 `app/android/key.properties` 配置 `storeFile`、`storePassword`、`keyAlias`、`keyPassword`。该文件已被忽略，权限应仅限所有者；不将其加入源码导出或 CI。

将已安装 Flutter 加入 PATH，并正确设置 JAVA_HOME、ANDROID_HOME。捕获并提交审查后的改造层后，从本仓库根目录构建：

```sh
python3 scripts/build-apk.py --checkout .work/dsh-go
```

release wrapper 要求改造层已提交、准备树与捕获的源码摘要一致、签名文件存在。它调用上游统一构建入口生成时间型 versionCode，写入精确源码提交 URL，输出 APK 与 SHA-256 到 `dist/`。发行包使用 `net.deepclub.agent`，适用于 Android 8+ arm64 侧载；不是 Google Play 配置。

debug 联调可显式指定：

```sh
python3 scripts/build-apk.py --checkout .work/dsh-go --debug --test-origin http://10.0.2.2:18453
```

该例外只在 debug 生效且限定 loopback/模拟器地址。release/profile 固定使用生产 origin，不接受该定义；正式站点需要先部署配套后端。

构建完成后校验实际 APK：

```sh
python3 scripts/verify-apk.py dist/deepclub-agent-0.1.0-arm64-release.apk \
  --build-tools "$ANDROID_HOME/build-tools/36.0.0" \
  --mapping .work/dsh-go/app/build/app/outputs/mapping/arm64Release/mapping.txt \
  --report dist/apk-verification.json
```

若构建没有启用 R8，则不传 `--mapping`。验证覆盖包名、版本、签名、受限素材、真实 DEX class definitions、R8 原类型映射与运行时归档摘要。签名证书的公开摘要可以发布，私钥和密码不可以。

## 更新改造层

仅在隔离源码树内修改，保留原版权与声明。图标从现有深云 SVG 母版生成；修改 ARB 输入后运行 l10n 生成器，不手改生成代码。

```sh
python3 scripts/capture-overlay.py --checkout /absolute/path/to/reviewed-source
```

已有生成层时，先审查再显式使用 `--refresh`。文本差异与资产新字节分开保存，以免 Git 二进制补丁携带上游受限图像的反向数据。随后用新的干净源码树运行 prepare，并比对 `overlay/source-state.json`。

运行 Node helper 测试时，`DSH_CREDENTIALS_PACKAGE` 指向固定 DSH host 的 `@deepseek-ai/dsh-credentials-local/package.json`；媒体工具测试通过其开发用 `node_modules` 链接使用同版本 DSH 模块。链接不进入改造层或 APK。真实 Android artifact 的 search-scope 测试另外使用 `DEEPCLUB_TEST_DSH_PREFIX`，其源摘要与独立执行证据见验证记录。

## English

Use the toolchain and immutable inputs above. `prepare.py` reconstructs the modified source and refuses dirty or drifted checkouts. `prepare-runtime.py` verifies and adapts the original runtime without importing upstream application code or artwork. Configure your own signing key outside version control, then use `build-apk.py` and `verify-apk.py`.

Release builds require a committed adaptation and matching source hashes. They embed a precise source URL. Debug test origins are restricted and cannot change release/profile production routing. Keep licenses and notices with source exports and distribution. Do not treat focused tests or emulator acceptance as physical-device or production verification.
