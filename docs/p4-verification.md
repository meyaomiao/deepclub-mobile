# P4 Android：真实服务与专属模拟器集成验收

执行单：[mobile#11](https://github.com/meyaomiao/deepclub-mobile/issues/11)，承接 [deepclub#444](https://github.com/meyaomiao/deepclub/issues/444) / [#480](https://github.com/meyaomiao/deepclub/issues/480)。本记录区分实际 Android UI、自动检查和未验范围；不代表生产发布或实体手机验收。

## 11 月 16 日续测

- 校验模拟器实际安装包的 SHA-256 为 `fe68d357e882ac2517c1b353043d1f11e81b77f2731288ebc91d3a208e8e20ab`（`fc8c150`）。账号 B 用系统相册选择账号 A 的新二维码，真实 Go 断言返回 403。App 显示同账号提示，B 随后在账户页刷新成功。
- B 先在网页取消本机 Agent 授权，再发起新授权并明确同意。API 换码通过。SQLite 只读核对取消授权未批准或消费，成功授权绑定新 Agent 会话，新旧会话的安装 ID 一致，旧会话已失效，新会话已绑定模型 Key。App 实际完成运行时准备、启动引擎、进入本机主页并在冷启后恢复。本轮本机模型列表为空。隔离目录仅销售 OpenAI chat-completions 测试模型，其能力和端点未进入 Android Agent 模型配置。
- B 将同账号新 Host 配对后，保留会话分别经 ADB 转发的直连和真实 Go 中转收到了受控模型的回复。两次实际网络详情均仍显示 Connecting、路径 Not confirmed。直连由活动 TCP 连接佐证，中转由移除该 Host 直连转发、恢复同一会话和 Go 完成连接日志佐证。
- 两条 Flutter 回归分别在直连、中转初态读取时发出连接变更，修复前都停留 Connecting。状态提供器改为先订阅广播、再读取当前状态，避免错过这次转变。两项回归、现有网关链路和网络组件合计 30 项通过，变更面静态分析通过，干净重建的 693 个源码摘要一致。
- 新 arm64 debug APK（versionCode `11161601`，SHA-256 `1996530ab02e866d18ca469afa5591fa7899aec86811c22aaacaca4d4a0d15f8`）通过签名及产物检查，保留安装数据更新。冷启恢复同一 Host 和会话，网络页显示 Connected / LAN；仅移除专属 AVD 到该 Host 的直连转发后，再次冷启显示 Connected / Relay，Go 记录本次中转连接正常完成。[直连截图](evidence/p4/12-verified-direct-network.png) · [中转截图](evidence/p4/13-verified-relay-network.png)

## 11 月 18 日 rc.3 Host 续测

- 固定输入：桌面 Host 由 `node scripts/p4/host.mjs` 启动，`runtime.json` 记录 source `dsh-v0.2.2-rc.3` / `38a6a5c965aa99ab525161efb7cc5cf1fe62fced`、gateway `721194ffbcbc1d93a80cfe91e4e53e1f3dc74e61`、adaptation `b2e58beeeabd6c46cbdf919a18eab694fba54ef7`（在 `bd446e6` 上仅增文档；Host2 的 runtime.json 相同）；同一真实 Go 二进制与隔离 SQLite。模拟器内安装包仍为 versionCode `11161601`，设备内 `sha256sum` 与上节 `1996530a…0d15f8` 一致（源码 `228f4f1` 线）。只启动专属 AVD `deepclub_p4_android36`（port 5580），未操作其他模拟器。
- 截图均由设备截屏缩至 960px，UI 判定以同名 `.ui.txt`（uiautomator 文本，输入框只记长度）为准。

| 场景 | 实际结果 |
|---|---|
| B 扫 A 的新二维码（前一代理执行，本次核对） | passed。B 已登录时经相册选择 A 的新 QR，Go 日志 `POST /api/client/remote/assertion` 为 403（03:58:11 PST，同时段无 429），App 显示同账号提示和 Scan again；随后账户页仍为 p4b、设备列表正常，B session 保留；B Sign out 后 Go `POST /api/client/logout` 200，页面进入 Clearing sign-in data。[403 提示](evidence/p4/rc3/00-b-403-same-account-hint.png) · [B session 保留](evidence/p4/rc3/00-b-session-retained.png) · [B 退出](evidence/p4/rc3/00-b-signout-clearing.png) |
| B 账户页 “Action needed / The operation failed…” | 发现（未修复）。403 与截图之间 Go 没有任何其他请求，因此不是新的网络失败。源码 `account_service.dart` 的 `_run` 把最后一次操作的 `DeepClubFailure.code`（此处为 `remote_identity_denied`）留在账户状态，`account_page.dart` 的 `deepClubErrorText` 未映射该码而落入通用文案。扫码页提示正确，账户页却显示陈旧的通用错误，直到下次账户操作清空；属 UX 缺陷，未在本轮修改。 |
| A 登录 → rc.3 Host 新二维码配对（LAN） | passed。B 退出后在 App 内用户名/密码登录 A（Go `POST /api/client/login` 200）；即时生成 120 秒 QR，经系统 PhotoPicker 选择，Go `remote/verify`、`assertion`、`check` 均 200，App 显示 P4 acceptance workspace（10 chats）。[配对后工作区](evidence/p4/rc3/01-a-paired-workspace.png) |
| LAN 短回复 | passed。新会话选择 P4 Deterministic Local Fixture，回复为 fixture 经真实 Go 模型代理的正文（0.8 秒、56 tokens）；fixture 计数 requests 2 / completed 2。[短回复](evidence/p4/rc3/02-a-lan-short-reply.png) |
| LAN `p4-long` Stop | passed。生成中输入框显示 Generating、按钮为 Stop generating；点击 Stop（因 uiautomator 取证耗时，实际约 15 秒，流仍在生成，30 个 chunk）后回复标 Stopped，轨迹显示 Reply (interrupted)。fixture `cancelled` 0→1，该请求 `completed=false`、`cancelled=true`。[Stopped](evidence/p4/rc3/03-a-lan-long-stopped.png) · [计数](evidence/p4/rc3/observe-lan-stop.json) |
| 打开 hello.txt | passed。会话详情 Files 列出 hello.txt（65 B），打开后正文与 Host 工作区文件逐字一致。[文件](evidence/p4/rc3/04-a-lan-hello-file.png) |
| Go relay 聊天 | passed。仅移除专属 AVD 的 `adb reverse tcp:18342`（保留 18340），force-stop + 冷启后未重登、未扫码，恢复同一会话；Go `remote/assertion`、`verify`、`check` 200。新消息经 relay 收到 fixture 回复（0.5 秒），本机 18342 无已建立连接。会话列表底栏为 “Current host: P4 isolated compiled Host, Relay”，网络详情为 Connected / Relay，时延显示 Not measured。[relay 回复](evidence/p4/rc3/05-a-relay-chat.png) · [网络详情](evidence/p4/rc3/06-a-relay-network.png) |
| 第二台电脑配对与切换 | passed（附缺陷）。`host2.mjs prepare` + `start` 后 Host2（18343，独立 gateway/key，同 rc.3 pin）在线；恢复 18342 reverse 并新增 18343 reverse。从 Switch host → Scan 即时生成 Host2 二维码并经相册选择，Go `assertion`/`verify`/`check` 200，App 进入 Host2，显示 No workspaces yet / No chats yet。在 Host2 的 Host default folder 新建会话，fixture 回复 “Hello Host2 only”。Switch host 切到主 Host：工作区为 P4 acceptance workspace，Today 会话只含本轮 LAN/relay 消息；切回 Host2：只有它自己的一条会话和 “Hello Host2 only”。两台电脑的会话与工作区互不出现。[Host2 空状态](evidence/p4/rc3/07-host2-paired-empty.png) · [Host2 会话](evidence/p4/rc3/09-host2-chat.png) · [切到主 Host](evidence/p4/rc3/11-switched-host1.png) · [切回 Host2](evidence/p4/rc3/12-switched-back-host2.png) |
| 在 rc.3 Host 上添加工作区 | failed（App 兼容缺陷）。Host2 的 Add workspace → Enter path 输入其工作区后显示 “This host can’t browse folders here”，Add 不可用。源码 `gateway_carrier.dart` 仅把 `0.2.2-alpha.2` / `0.2.2-rc.1` 当作已知版本，rc.3 源码 `package.json` 版本为 `0.2.2-rc.3`，于是只放行 `_compatibleChatReads`：`workspace/create`/`rename`/`delete`、`directoryPicker/createDirectory`、`terminal/*` 创建类和 `agentPresets/select` 均不在手机端放行集合内。该页提示与此推断一致，但本轮未单独抓取 RPC 拒绝记录。新 Host 的工作区管理需在 App 识别 rc.3 后复验。[阻塞页](evidence/p4/rc3/08-host2-add-workspace-blocked.png) |
| 审批（单个 App） | passed。Host2 会话默认 Workspace write（ask）。发送 `p4-approval-outside` 后，第一次在工作区外写入被沙箱拒绝，目标目录仍为空；fixture 随后发出一次同命令的提权请求。App 在会话内显示审批卡片：完整命令、Decline / Allow once / Allow for chat，标题栏为 Needs approval。点击 Allow once 后命令只执行一次，`marker.txt` 恰好一行 `p4-approval-outside-ok`；fixture 计数 initial 1 / escalation 1 / final 1，回合 Completed · 2 tool calls。没有注入审批事件，也没有改全局或会话权限。[审批卡片](evidence/p4/rc3/13-host2-approval-sheet.png) · [允许后](evidence/p4/rc3/14-host2-approval-allowed.png) |
| 审批单赢家（多客户端竞争） | not run。本轮只有这一个 Android App 连到 Host2：iOS 属其他会话，不能动；没有第二台手机；Host2 网页端需另外登录浏览器会话。没有用协议脚本代替第二个 UI 客户端。上面的单 App 结果不能证明晚到方被拒，也不能证明另一端的卡片会消失。 |

源码观察（未执行验证）：`gateway_carrier.dart` 只把 `0.2.2-alpha.2` / `0.2.2-rc.1` 视为已知版本，其他版本会去掉 `harness.terminal.v1` 和终端 retain/attach 流。rc.3 Host 因此按兼容模式处理终端和工作区写操作；实际影响见上表 “添加工作区” 行，终端本轮未测。

以下各节保留首轮执行的固定输入和历史结果。

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
| 新干净准备树重建 overlay | passed；共享只读固定上游对象、重新 prepare，692 个源码摘要全部匹配；不复制运行时/构建 cache |
| PKCE 修复包与网络/错误修复包 APK artifact 校验 | passed；均签名 v2、受限资产 0、排除的原生 class definitions 0 |

不重新运行 P3 全量截图与全套检查。既有 72 张组件矩阵属于 P3 的合成组件证据；本次主体执行截图来自真实 Android UI。网络详情修复另附 24 张明确标记的组件矩阵：LAN/relay × 中英 × 浅深 × 360dp/360dp@1.3/840dp，25 个 UI 检查（含既有 SSH 分支）通过。组件使用真实 Noto Light 300 / Regular 400 / Bold 700，人工抽看英文 360dp@1.3 与中文深色；不把组件结果当作修复后 APK 的实际设备结果。未宣称新增真机覆盖。

运行时脚本、lock 和插件输入与冻结 P3 相同。校验 `overlayRevision=9860307c7e5b4cd16aaf679af9abec2948802fdd6cf51c7adc1a671c141fbfe7` 后，通过 APFS clonefile 复用其已验证公开运行时输出，并运行 bundle 校验，避免重复压缩未改变的 rootfs。没有复制凭据或用户配置。

## 首轮执行环境问题

初始数据卷不足 1 GiB，AVD 拒绝启动；首次 APK 构建在 `mergeArm64DebugNativeLibs` 因 ENOSPC 失败。Root 清理已完成任务的可重建缓存，串行构建/VM；本任务 Gradle 限制 JVM 2 GiB、单 worker、Kotlin in-process。初始软件 GPU 下 SystemUI/系统浏览器出现 ANR；本轮专属 AVD 改为 host GPU，内存压力解除后实际网页登录正常。失败与恢复均不归为 App 成功。最后在唯一 Android UI 窗口以 `install -r` 安装网络/错误修复包后，B 扫码页已恢复，但出现明确的 `Process system isn't responding` 系统 ANR；未刷新二维码、未发新配对请求，即正常关闭任务 App/AVD 保留数据。系统 ANR 阻塞 B 403 与新网络状态页复验，未把它归因 App 或用组件通过替代实际结果。

## 首轮实际执行进度

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
| 账户 B 错账号隔离 | 未完成；B 已通过真实网页 PKCE 登录，首轮扫码先被共享 IP critical 限流的空体 HTTP 429 拦截，未到 Host verify。自然冷却后最终修复包 install-r 恢复 B 扫码页，但 Android Process system ANR，按资源门槛在 fresh/配对前停止；不能当成跨账号 403 已验证 |
| 网络详情修复后的实际 UI | 未完成；新包已构建/校验/安装并保留 B session，但同一次系统 ANR 阻塞最终 LAN/relay 状态页复验。25 项核心回归与 24 张组件矩阵 + SSH 回归均已通过，不能替代此项 |
| 审批 | 未验；当前会话权限 UI 仅有 Read only / Workspace write / Full access，没有 Ask；未改全局/会话权限，未用协议探针替代审批 UI |

凭据、授权码、verifier、Cookie、手机 session、设备 token 和有效二维码不进入本记录或截图。测试账号密码与短效二维码只在任务私有文件中。

## 证据索引

初次空安装、remote-only 与首张 consent 截图来自原点修复包 `7985e17`（versionCode 11161112），它真实暴露 400 换码失败。后续成功主链（扫码至退出冷启）使用 PKCE 修复 APK `4d37f7550c70d6961363c2d64a5d46b7b3d9c715`，versionCode 11161219，SHA-256 `6ef057ba78e0a1fcb827b9d6f76c23f3b5a9ac8e44cf69a34e3a9d42d093b7ea`。后续网络/错误提示修复包：源码 `fc8c150d824707f4e6db2e444a7490c4c3ceb747`，versionCode 11161501，SHA-256 `fe68d357e882ac2517c1b353043d1f11e81b77f2731288ebc91d3a208e8e20ab`。该包构建、artifact 校验和保数据更新安装通过，但其最终状态页与 B 403 复验被系统 ANR 阻塞，不能混用旧包截图冒充新 UI。

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
| 产物 / 未安装本机引擎 | [最终 APK 校验](evidence/p4/apk-verification.json)、[实际主链 APK 校验](evidence/p4/apk-pkce-verification.json)、[rootfs 缺席实证](evidence/p4/runtime-absence.json) |
| 新包最终 UI 阻塞 | [Android 系统 ANR](evidence/p4/11-system-anr-after-update.png)，未到新 B 403/网络状态页复验 |
| 合成组件矩阵 | [网络详情 24 组合](evidence/p4/network-components/)（明确不是 Android App 实机截图） |

Host / model 全局计数还受 iOS 后续业务影响，不把共享累计值全部归于 Android；只按相应窗口差量与持久会话结果相互验证。

## 首轮收尾与保留

本任务专属 AVD 已正常关闭，最终 `adb devices -l` 无设备。所有管理的编译、分析、下载、截图与模拟器 jobs 已结束或显式取消；按本任务 cwd 的 `ps` / `lsof` 检查未发现残留 Java/Dart/Flutter tester、Xcode、curl 或 emulator 进程，没有停止用户全局进程。保留任务 worktree、prepared/reconstructed 源、公开构建缓存、私有 AVD 数据与最终 debug APK，供资源恢复后继续两项实际复验；私有数据与缓存不进 Git。Issue/PR 保持 Open/Draft，没有 merge、Ready、release 或生产部署。

## 尚未覆盖

实体 Android 手机与 ROM、真实相机扫描外部显示屏、物理 LAN、真实跨公网、生产服务器、付费模型、release/profile 安装验收、本机 Agent 模型推理、多端审批和同账号两台电脑间切换仍待验证。

AI-assisted implementation and verification.
