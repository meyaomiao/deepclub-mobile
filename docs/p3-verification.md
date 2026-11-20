# Android P3 功能整合验证 / Android P3 integration verification

Contributor；AI-assisted，保留原版权、AGPL、第三方声明和受保护的 New API / QuantumNous 署名。执行单 [mobile#9](https://github.com/meyaomiao/deepclub-mobile/issues/9)，承接 [mobile#8](https://github.com/meyaomiao/deepclub-mobile/issues/8)、[deepclub#444](https://github.com/meyaomiao/deepclub/issues/444) / [#480](https://github.com/meyaomiao/deepclub/issues/480)。本记录仅描述本次本地验证，未合并、部署、发布、上传/分发 APK 或安装用户设备，未调用付费模型。

## 来源、隔离与重建

- 最新 `origin/main` 为 `f947f04`；独立 `codex/issue-9-android-p3-integration` 分支叠加冻结 P0 [PR #6](https://github.com/meyaomiao/deepclub-mobile/pull/6) 的 `17f02726d3468b3f6f684de80fd0001cf8a32b4e`。Draft 以冻结的 `codex/issue-5-android-p0` 为审查基线，P0 合入后再调整目标。
- 上游保持 `288234ae52fdfcfc2b0a0388763c371d0b09ea7d`。原进行中 prepared 树只读；导入前后两次快照的 tracked diff SHA-256 都是 `e798091a8c1ab8a133b7c9f5cdb13e80c44209157bcb2fa8f1f32e670ee6fdc2`，tracked WIP 280 文件。安全源快照 manifest 摘要为 `8b6bbaf00227709a4e832dd7c4d773150e9806c773f55055d64ed5c8a8d131f7`。
- 导入 333 个安全新增源文件；排除 `.DS_Store`，未复制缓存、账号凭据、签名或 `local.properties`。这不代表原作者停止工作，也没有覆盖原工作树。
- 实际代码、双语 ARB 输入及生成结果由 `capture-overlay.py --refresh` 捕获，最终为 408 个新增文件、69 个资产替换、6 个资产删除。干净重建和 prepared 的 **688 个源路径逐一校验相同**；`overlay/source-state.json` 的 SHA-256 为 `84f7b42bd3231cd125d2881fa79f4067ae68dc24a55cf89ce805ff408029779f`。
- 本地专属路径为本仓库 `.work/prepared` 与 `.work/rebuilt`；各自 HEAD 都保持固定上游。测试日志、运行时、下载依赖及 debug 签名位于本仓库忽略的 `.work/` 中，没有改用户 SDK、模型或运行 profile。未修改原 clone/global git 身份配置；提交使用单次作者环境，身份与仓库历史 meyaomiao 一致。

```sh
python3 scripts/capture-overlay.py --checkout .work/prepared --refresh
python3 scripts/prepare.py --checkout .work/rebuilt
```

## 实际功能与契约

- [gateway pairing](../overlay/new/app/lib/remote/gateway_pairing.dart)、[carrier](../overlay/new/app/lib/remote/gateway_carrier.dart)、[link](../overlay/new/app/lib/remote/gateway_link.dart)、[gateway state](../overlay/new/app/lib/state/gateway_state.dart) 和 [扫码页](../overlay/new/app/lib/ui/remote/gateway_pairing_page.dart) 是实际功能源码。二维码/相册/粘贴/深链走统一解析与同账号配对；设备 token 在 Keystore，主机 metadata 和账号绑定分开保存。
- 沿用原项目、会话、文件、终端、审批与提问 UI。Host 切换清理旧会话选择/模型意图/审批；退出、撤销及账户绑定变化使旧 gateway 停止使用。普通连接页和运行位置菜单只显示扫码电脑/此手机，移除可见 SSH 表单及 SSH 主机行，不要求填写网关或 API Key。
- 修正已知/兼容两份 allowlist：`permissionPresets/catalog`、`agentPresets/list`、`agentPresets/select`。客户端必须与桌面 advertised allowlist 取交集；旧错误端点名、未知管理方法和凭据接口继续拒绝。未知 DSH 版本只保留已知聊天/读取能力，不开放 Agent 选择写入和终端。
- 修正 `wss:` 的 Dart URI 默认端口问题：未显式端口也能识别固定 DeepClub 中转。非 443 端口、错误域名/路径、凭据 URL、过期/错误身份仍拒绝。HTTPS 显式默认 443 经 Dart 规范化为同 origin；测试使用实际不同的 8443 验证拒绝。
- 只连接电脑登录不安装/启动本机、不 provision 模型 Key、不读取 agent-config、不自动写远端模型配置。恢复和网络失败保留授权身份；移除按模式生成第二个 UUID 的绕过。只对曾用 `remote_device_id` 的已授权 remote 记录迁移原值为单一 `device_id`。
- [account service](../overlay/new/app/lib/deepclub/account_service.dart) 采用 [后端 #508](https://github.com/meyaomiao/deepclub/pull/508) / `1e6f29427dcbbc6e0fb496b47e6c2710bb5f92d5` 的最终契约：当前 remote Bearer 创建 `/api/client/agent-upgrade/intents`，新 state/S256 verifier；只打开原站点受控相对授权 URL。网页明确同意后使用 `deepclub-android-agent-upgrade-v1` 兑一次新 Agent 会话，不把旧 Bearer 交给 token 或浏览器。
- 完整解析新会话、核对原账户 `user.id`、`client_type:agent`、原 `device_id` 和非空 Key 后才转换。兑换前不 logout、不 provision、不改模式、不安装；取消、拒绝、网络失败、畸形响应或错误用户/设备均保留旧 remote。兑换成功后保存新绑定、清旧 gateway，准备本机；之后配置获取失败保留已授权的新 Agent 并可重试。pending 总窗口覆盖 intent 5 分钟 + 批准后 code 5 分钟，服务端独立校验权威期限，不自动重兑网络结果不明的一次码。

新能力还依赖冻结的 [后端 P1 #501](https://github.com/meyaomiao/deepclub/pull/501) / `a58fe2b5a95de2eee0fe224813a15ef2c1c610aa` 与 [桌面 #43](https://github.com/meyaomiao/deepclub-desktop/pull/43) / `03e7cf9`。Draft 和 CI 不代表线上已部署。

## 本地实际执行结果

工具链：Flutter **3.47.7** / Dart **3.13.5**、JDK 17.0.20.1、Android SDK API 35/36、build-tools 36.0.0、NDK 28.2.13676358。pub 保持原锁文件；PUB_CACHE、Gradle cache 和 ANDROID_USER_HOME 均在新树内。没有私有签名输入。

| 检查 | 结果 | 说明 |
|---|---|---|
| `flutter pub get --enforce-lockfile` | 通过 | 独立缓存，未升级依赖 |
| 完整 adaptation suite（下列命令） | 154 tests 通过 | parser/carrier/account/state/UI/图标/架构；包括 13 个同设备升级用例 |
| 最后授权按钮布局调整后的 `remote_ui_test.dart` | 11 tests 通过 | 含新增 360dp 英文 **2.0×** 字号文字被按钮包住的几何断言；其余 1.3×/宽屏状态检查 |
| `flutter analyze --no-pub` | 无问题 | 完整应用及测试分析 |
| `l10n_merge.py --check` | 通过 | 72 parts / 7416 keys；仅改成对 ARB 后运行生成器 |
| 原生精选 JVM tests | 15 tests 通过 | GuestSetup 9、LauncherManifest 3、PictureShortcuts 3，无跳过；完整上游原生源集不在通过声明内 |
| 本地 conversation replay viewer | 3 tests 通过 | 含本地图片回放与禁用 hosted fetch；生成器 `--check` 通过 |
| 组件 golden capture | **72 张通过** | 中/英 × 浅/深 × 360@1.0、360@1.3、840@1.0 × 6 状态，人工看关键图 |
| 干净重建 | 688 / 688 摘要一致 | 固定上游、路径集合、文件内容摘要均相同 |
| `check_runtime_bundle.py arm64` | 通过 | schema 1，5 项 runtime 输入 |
| debug APK 编译 + `verify-apk.py` | 通过 | 真实 Android arm64 包及 DEX/资产检查，未安装设备 |

```sh
# 在 prepared/app，设定固定 Flutter 和真实字体目录后：
flutter test --no-pub --reporter expanded --concurrency 2 \
  test/deepclub test/deepclub_surface test/brand/site_update_test.dart \
  test/icons/app_icons_test.dart test/arch/import_direction_test.dart
flutter test --no-pub test/deepclub/remote_ui_test.dart
flutter test --no-pub --update-goldens test/deepclub/remote_ui_capture.dart
flutter analyze --no-pub
python3 tool/l10n_merge.py --check
flutter build apk --debug --no-pub --flavor arm64 --target-platform android-arm64
# 在 prepared/app/android，使用本仓脚本筛选已有原生测试：
./gradlew testArm64DebugUnitTest -I <adaptation>/scripts/test-native-brand.gradle \
  -x compileFlutterBuildArm64Debug --console=plain
```

首次本地 Flutter native hook 的 SQLite 公网下载超时，不计作测试成功。随后通过官方 `sqlite3-3.9.1` release 下载原资产并匹配包内固定哈希，填充仅新树的 hook cache后运行成功，没有改依赖或跳过摘要：macOS arm64 `38c4a60bacdf3f4fddcb90fae011e06e5ebade251870a960cbb5284cb64783ea`；Android arm64 `e684ef8646ffd48b95bae58bf29c55ffd85acebac2a7118ffde9fd02df37d629`。

字体为官方 Noto Sans CJK `Sans2.004` 的真实 Light/Regular/Bold TTC，沿用 P0 固定 SHA 检查；字体仅作为测试依赖，不进入 overlay/APK。原 Gradle/flutter_webrtc KGP 兼容提醒仍存在，未借机升级依赖。

## 实际 Dart → 桌面 Host

[真实 gateway probe](../overlay/new/app/test/deepclub/real_gateway_probe.dart) 是 **Flutter test 中的实际 Dart GatewayCarrier + DshClient**。它连接只在本任务目录启动的实际 DSH CLI/profile、已编译的桌面 gateway `721194ffbcbc1d93a80cfe91e4e53e1f3dc74e61`，账户断言/模型服务为合成 fixture。它不是 Node smoke 输出的转述，也不是生产 Go 后端或手机真机证据。

- 新配对 → 保存 token → 新 carrier 重新鉴权 → mux `$events` ready，成功。
- 桌面真实 advertised allowlist 中三条正确 RPC 均可用；实际 `session/create`、`permissionPresets/catalog`、`agentPresets/list/select` 成功。
- 在实际电脑 workspace 读取 `hello.txt` 的列表与文本成功，文件内容与 fixture 写入一致。
- `credentials/get` 和两条旧错误端点均返回 `METHOD_NOT_ALLOWED`；LAN 路径若尝试读取手机 relay session 会直接使测试失败。
- 该 probe 1 test、exit 0；没有发任何模型请求。独占 Node fixture/Host 在测试后停止，其数据仅留在本任务 `.work/`。

```sh
DEEPCLUB_GATEWAY_INFO=<exclusive-fixture-state.json> \
  flutter test --no-pub test/deepclub/real_gateway_probe.dart
```

## 截图矩阵与 UI 自查

所有图由真实生产组件和合成 public provider 状态生成；扫码预览是明确的 **camera placeholder**，不能当作真实相机/相册/权限画面。全套 72 张位于 [goldens/macos](../overlay/new/app/test/deepclub/goldens/macos)，生成入口为 [remote_ui_capture.dart](../overlay/new/app/test/deepclub/remote_ui_capture.dart)。

| 状态 | 深色中文 360 | 浅色英文 360@1.3 |
|---|---|---|
| 扫码准备 | [图](../overlay/new/app/test/deepclub/goldens/macos/remote_scan_dark_zh_phone.png) | [图](../overlay/new/app/test/deepclub/goldens/macos/remote_scan_light_en_phone_large.png) |
| 正在核验/连接 | [图](../overlay/new/app/test/deepclub/goldens/macos/remote_pairing_dark_zh_phone.png) | [图](../overlay/new/app/test/deepclub/goldens/macos/remote_pairing_light_en_phone_large.png) |
| 二维码过期 | [图](../overlay/new/app/test/deepclub/goldens/macos/remote_expired_dark_zh_phone.png) | [图](../overlay/new/app/test/deepclub/goldens/macos/remote_expired_light_en_phone_large.png) |
| 账号不一致 | [图](../overlay/new/app/test/deepclub/goldens/macos/remote_account_mismatch_dark_zh_phone.png) | [图](../overlay/new/app/test/deepclub/goldens/macos/remote_account_mismatch_light_en_phone_large.png) |
| 明确启用本机 | [图](../overlay/new/app/test/deepclub/goldens/macos/remote_upgrade_dark_zh_phone.png) | [图](../overlay/new/app/test/deepclub/goldens/macos/remote_upgrade_light_en_phone_large.png) |
| 等待浏览器授权 | [图](../overlay/new/app/test/deepclub/goldens/macos/remote_upgrade_waiting_dark_zh_phone.png) | [图](../overlay/new/app/test/deepclub/goldens/macos/remote_upgrade_waiting_light_en_phone_large.png) |

宽屏复核：[深色英文扫码](../overlay/new/app/test/deepclub/goldens/macos/remote_scan_dark_en_wide.png)、[浅色英文启用](../overlay/new/app/test/deepclub/goldens/macos/remote_upgrade_light_en_wide.png)。

- [x] 涉及状态有明确文案；同区域至多一个进度，只有失败才显示重试/重新扫描。
- [x] 沿用 300ms 延迟 / 500ms 最短 loading presentation；局部 Quiet spinner，不做整屏转圈。
- [x] 一个主操作；授权期间按钮保持原文案和位置，可取消；按钮加垂直留白以容纳大字号。
- [x] 新增布局用 AppSpace；授权内容宽度不超过 520dp，扫码内容列居中。中/英文、浅/深色、360 与 840 均复核；2.0× 英文授权按钮新增几何测试通过。
- [x] 新文案不暴露内部 RPC/PKCE/网关/Key 或完整设备 ID；图标只经 AppIcons。普通入口没有 SSH/API Key 表单。
- [x] 加载/错误有语义状态；主按钮未遮挡，页面可滚动。
- [ ] 相机实际权限拒绝/系统设置返回、相册选图解码、TalkBack、系统深链的 Android 设备截图：本次未运行。
- [ ] 真实离线/撤销/电脑身份变化后的设备截图、电脑连接成功后的生产项目/审批屏幕矩阵：本次未运行；相应协议和状态由自动检查覆盖，不能替代设备画面。

## APK 与未验证边界

本地 debug APK：`prepared/app/build/app/outputs/flutter-apk/app-arm64-debug.apk`，280624033 bytes；SHA-256 `a664a0d149f03972c79595bb1a50021c0eca27bcc7b7af7cbeeeff0cb7b29914`，version `0.1.0` / code `11160134`。所有 locale label 为 DeepClub；v2 签名验证通过；受限美术 0；排除的原生 class definitions 0（检查 21081 个 DEX class definitions）；运行时 `deepclub-1-9860307c7e5b`，归档摘要 `cd3931ce228f2c9ac589cdc78d0bd985bd268d5b9c905b0c8aeb949147558a79`。这只是独占 debug 签名的本地验证包，未上传、分发、安装设备，也没有 production source URL/release 签名验收声明。

未运行：Android 模拟器/实体设备安装、真实相机与相册、Android 系统回调与各 ROM、真实用户账户/付费模型、真实 Go 后端与手机/电脑全链路、跨公网/不同 Wi-Fi、macOS 文件权限对话框、Windows 桌面、生产撤销延迟和发布验收。现有工作区/流式/停止/generation/审批生命周期自动测试与真实 Host 文件 probe 均有用，但不等同于上述真实环境验收；本 PR 保持 Draft。

## English

This Contributor/AI-assisted integration captures the ongoing #8 source without writing to its worktree, fixes the actual RPC allowlists and WSS default-port handling, preserves the mature native session/workspace/file/approval UI, and implements explicit same-installation Android remote-to-Agent consent using backend #508. Cancellation, failed exchange and malformed/mismatched results retain the remote authorization; configuration failure after successful exchange retains the new Agent for retry.

Local evidence: 154 adaptation tests, 11 final focused UI tests including 2× English button geometry, 15 selected native JVM tests, 3 replay-viewer tests, clean analysis, 72 synthetic component captures, 688 matching prepared/rebuilt source hashes, and a compiled/verified arm64 debug APK. The actual Dart carrier successfully accessed the real desktop Host/gateway using a synthetic authority, including permission/Agent RPCs and workspace text reads; no model request was made. Camera/album/device/deep-link/real-network/Windows/production acceptance remains unverified. No merge, deployment, APK distribution, device installation, upstream contact, paid model call, user profile/model change or private signing input is included.
