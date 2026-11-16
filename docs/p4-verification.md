# P4 Android：真实服务与专属模拟器集成验收

执行单：[mobile#11](https://github.com/meyaomiao/deepclub-mobile/issues/11)，承接 [deepclub#444](https://github.com/meyaomiao/deepclub/issues/444) / [#480](https://github.com/meyaomiao/deepclub/issues/480)。本记录区分实际 Android UI、自动检查和未验范围；不代表生产发布或实体手机验收。

## 输入与隔离

- 从最新 mobile main `f947f0462151bcb0880312f14ca9621350722720` 建分支 `codex/issue-11-p4-integration`，fast-forward 叠加冻结 mobile P3 `4d59b003c7981be853a00e034d1cbbb415f731ac`。独立 P4 worktree，原 P3 源树只读。
- 后端：独立真实 Go/Default 网页，包含冻结 #501 + #508；执行环境由 root 的 [deepclub#509](https://github.com/meyaomiao/deepclub/issues/509) 维护。桌面：冻结 #43 的实际 DSH Host。账户 A/B 由独立数据库创建，不使用私人账号。
- Flutter 3.47.7 / Dart 3.13.5、JDK 17.0.20.1；固定上游 `288234ae52fdfcfc2b0a0388763c371d0b09ea7d` 与原锁文件。
- 专属 Android 36 AOSP default arm64-v8a image revision 2、emulator 37.1.11，任务 AVD `deepclub_p4_android36`，port 5580。独占 ANDROID_USER_HOME / ANDROID_AVD_HOME / Gradle / pub cache。未操作既有 AVD 或实体设备，未接受新 SDK 法律协议。
- `adb devices -l` 初始无任何设备。因此本记录所有设备结果均为模拟器。API/relay `http://127.0.0.1:18340` / `ws://127.0.0.1:18340/ws/mobile/<gatewayId>`，Host LAN socket `ws://127.0.0.1:18342/ws/mobile`；通过专属模拟器的 ADB reverse 到本机。此网络不是物理 Wi-Fi 或跨公网。
- debug origin 复用原有 DEEPCLUB_TEST_ORIGIN 白名单（loopback / Android host alias）。release/profile 始终生产 origin；没有新增普通 UI 地址配置。LAN socket 不发送手机账户 session。
- 模型由本地受控 fixture 经真实 Go 模型代理提供，不发生付费模型调用；仅任务 Host 的 custom preset 使用该配置，不改既有用户模型/思考选择。

## 实际 UI 发现与修复

1. 系统浏览器真实 Go 登录与授权后，App 的 `/api/client/token` 返回 HTTP 400。Go 授权记录仍未消费，未创建该手机 session。原因是 Android 仅在 upgrade 兑换中发送 client_type，普通 remote PKCE 缺失 `android_remote`。修复为每次换码显式发送 pending 角色：remote=`android_remote`，普通/upgrade Agent=`agent`，保留后端严格角色校验。
2. 同一次失败返回 App 后没有错误提示。实际回调与 Android resumed 自动刷新并发，后者在没有 session 时仍进入 `_run`，清掉了 `invalid_grant`。修复为没有 session 时同步直接完成；显式新登录仍会清除旧错误。没有新增文案或修改界面布局。
3. 为实际本地 Go relay 联调，relay 信任 origin 从既有固定服务 origin 派生，并校验 scheme/host/port、gateway UUID 路径、无 userinfo/query/fragment。debug 仅信任所编译本地 origin；正式构建继续只信任生产 WSS。
4. 实际 RPC/relay 正常时，抽屉仍显示 Connecting，网络详情错误显示 SSH。源码证实 GatewayHostLink 重复 open 把状态重置为 connecting，而已连接 mux 不再发 connected 事件；详情页也只区分旧 relay 与 SSH。修复为读取真实 mux 状态并暴露仅 LAN/relay 的安全枚举，详情页显式识别 gateway，不展示原始端点/凭据、不伪造延迟测量，保留 SSH 分支。
5. B 扫码遇到共享 IP critical 桶（20 次 / 1200 秒）空体 429，原解析变成 generic invalid_response。修复为安全的 rate_limited 与“稍后再试”提示；未清桶、未重启限流、未放宽后端规则。B 身份验证结果仍需与限流结果分开记录。
6. 冻结 Go 的 403 remote_identity_denied 是不同电脑账号的拒绝，不表示手机 session 失效。客户端现在保留该稳定码、显示既有同账号提示，且不清除有效手机 session。未知 403 的既有失效清理语义保留。该项先经回归检查，实际 B 单次复验另列。

## 自动检查

| 检查 | 结果 |
|---|---|
| gateway pairing/carrier + relay origin，生产默认 | 16 passed |
| `--dart-define=DEEPCLUB_TEST_ORIGIN=http://127.0.0.1:18340` relay origin 专项 | 1 passed |
| remote_account + pkce + agent_upgrade | 24 passed；包含严格 token client_type、失败回调/resume 并发与显式重试 |
| account_service + account_state | 12 passed；覆盖共享同步与冷启动回调 |
| 网络状态/错误处理新回归（gateway_link + client_api + remote_account + carrier） | 25 passed；含重复 open、真实 fixture socket 的连接状态与路由、空体 429、有效手机 session 保留、无 Host/relaySession 访问 |
| 网络 UI 24 组合 + 既有 SSH 分支 | 25 passed；组件截图不代替实际 APK |
| 修改的 relay/account/网络 UI 源码与相关测试静态分析 | passed；l10n_merge --check 7418 keys |
| `check_runtime_bundle.py arm64` | passed，schema 1、5 files |
| PKCE 修复包与网络/错误修复包 APK artifact 校验 | passed；均签名 v2、受限资产 0、排除的原生 class definitions 0 |

不重新运行 P3 全量截图与全套检查。既有 72 张组件矩阵属于 P3 的合成组件证据；本次主体执行截图来自真实 Android UI。网络详情修复另附 24 张明确标记的组件矩阵：LAN/relay × 中英 × 浅深 × 360dp/360dp@1.3/840dp，25 个 UI 检查（含既有 SSH 分支）通过。组件使用真实 Noto Light 300 / Regular 400 / Bold 700，人工抽看英文 360dp@1.3 与中文深色；不把组件结果当作修复后 APK 的实际设备结果。未宣称新增真机覆盖。

运行时脚本、lock 和插件输入与冻结 P3 相同。校验 `overlayRevision=9860307c7e5b4cd16aaf679af9abec2948802fdd6cf51c7adc1a671c141fbfe7` 后，通过 APFS clonefile 复用其已验证公开运行时输出，并运行 bundle 校验，避免重复压缩未改变的 rootfs。没有复制凭据或用户配置。

## 执行环境问题

初始数据卷不足 1 GiB，AVD 拒绝启动；首次 APK 构建在 `mergeArm64DebugNativeLibs` 因 ENOSPC 失败。Root 清理已完成任务的可重建缓存，串行构建/VM；本任务 Gradle 限制 JVM 2 GiB、单 worker、Kotlin in-process。初始软件 GPU 下 SystemUI/系统浏览器出现 ANR；本轮专属 AVD 改为 host GPU，内存压力解除后实际网页登录正常。失败与恢复均不归为 App 成功。

## 实际执行进度

| 场景 | 实际结果 |
|---|---|
| 空安装与首屏 | passed；实际安装 debug APK，首屏 DeepClub 登录入口 |
| 选择 Only connect to my computer | passed；页面明确本机引擎不安装 |
| 系统浏览器 Go 网页登录 A、remote consent、真实 deepclub callback | passed；首轮暴露上述 400，修复包以 `install -r` 保留安装数据后重新发起新 PKCE，真实浏览器 Allow access 自动回 App 并进入已登录扫码页 |
| remote-only 不安装运行时 | passed；实际 UI 显示 Local engine not installed，debug `run-as` 只读检查 `files/runtime/rootfs` 不存在 |
| 相册二维码、实际 Host 配对、项目 | passed；系统 PhotoPicker 选择真实私有 QR PNG，App 解码后显示已有 P4 acceptance workspace 及其 2 条已登记会话；在该电脑项目中新建本轮任务会话 |
| QR 过期 | passed；旧图确已过期约 151 秒，App 拒绝；手机与宿主时钟差小于 1 秒。重新即时生成正常 120 秒 QR 后配对成功，没有放宽时限 |
| LAN 真实回复与停止 | passed；任务新会话仅选择本地受控 fixture。短回复显示真实 Go 代理正文；第二条长流 2.3 秒点击 Stop，显示 Interrupted。第一条长流因自动化等待 idle 自然完成 60 秒，不算 Stop 证据 |
| 文件浏览 | passed；实际 Files tab 列出 hello.txt 并打开，UI accessibility 完整 marker 与测试文件一致 |
| 保存配对的 relay 冷启动 | passed；移除仅本 AVD 的 reverse 18342、force-stop + launch，保留 18340，未重登/未扫描，恢复原任务会话/模型/历史并实际发送新消息 |
| relay 真实停止与工具 | passed；长流再次在 2.3 秒 Stop；精确 p4-tool-read 实际触发 Read hello.txt，UI 展开 Lines 1–1 与 marker，2 steps / 112 tokens。Host 持久 tool/result isError=false 且 marker=true |
| 当前手机退出及冷启 | passed；只点击账户页 Sign out 并确认，未操作其他设备撤销；重新冷启仍为 remote 登录页，无旧项目/配对自动恢复。Go relay 完成连接计数 2→3 |
| 账户 B 错账号隔离 | 待单次冷却复验；B 已通过真实网页 PKCE 登录，但本轮扫码先被共享 IP critical 限流的空体 HTTP 429 拦截，未到 Host verify，不能当成跨账号 403 已验证 |
| 审批 | 未验；当前会话权限 UI 仅有 Read only / Workspace write / Full access，没有 Ask；未改全局/会话权限，未用协议探针替代审批 UI |

凭据、授权码、verifier、Cookie、手机 session、设备 token 和有效二维码不进入本记录或截图。测试账号密码与短效二维码只在任务私有文件中。

## 证据索引

真实 App 主链使用 PKCE 修复 APK `4d37f7550c70d6961363c2d64a5d46b7b3d9c715`，versionCode 11161219，SHA-256 `6ef057ba78e0a1fcb827b9d6f76c23f3b5a9ac8e44cf69a34e3a9d42d093b7ea`。后续网络/错误提示修复包的实际复验单列，不能混用旧包截图冒充新 UI。

| 类型 | 证据 |
|---|---|
| 空安装 / remote-only | [首屏](evidence/p4/01-empty-install.png)、[选择 remote-only](evidence/p4/02-remote-only.png) |
| 真实网页 consent / 已登录扫码 | [Go 网页授权](evidence/p4/03-web-remote-consent.png)、[实际扫码页](evidence/p4/04-authenticated-scanner.png) |
| 实际项目列表 | [已有工作区与 2 chats](evidence/p4/05-paired-workspaces.png) |
| 实际 LAN 文本流 / 停止 | [生成中](evidence/p4/06-live-stream.png)、[2.3 秒 Interrupted](evidence/p4/07-stopped-stream.png) |
| 实际文件浏览 | [文件 UI](evidence/p4/08-remote-file.png)、[UI 完整 marker](evidence/p4/file-ui.json) |
| 实际 relay 工具结果 | [展开 Read 工具](evidence/p4/09-relay-tool-result.png)、[Host 持久结果](evidence/p4/tool-result.json) |
| 实际退出后冷启 | [保持未登录](evidence/p4/10-cold-start-signed-out.png) |
| 独立服务观测 | [LAN Stop](evidence/p4/observe-lan-stop.json)、[relay Stop/read](evidence/p4/observe-relay-stop-read.json)、[退出后 relay 完成计数](evidence/p4/observe-after-logout.json) |
| 产物 / 未安装本机引擎 | [APK 校验](evidence/p4/apk-verification.json)、[rootfs 缺席实证](evidence/p4/runtime-absence.json) |
| 合成组件矩阵 | [网络详情 24 组合](evidence/p4/network-components/)（明确不是 Android App 实机截图） |

Host / model 全局计数还受 iOS 后续业务影响，不把共享累计值全部归于 Android；只按相应窗口差量与持久会话结果相互验证。

## 尚未覆盖

实体 Android 手机与 ROM、真实相机扫描外部显示屏、物理 LAN、真实跨公网、生产服务器、付费模型、release/profile 安装验收、本机 PRoot Agent 与本机授权升级的实际 UI。本轮模拟器验证不能替代这些验收。

AI-assisted implementation and verification.
