# 深云移动端适配方案

> 2026-11-13 版。以 [DSH Go `288234a`](https://github.com/ccch1mneyyy/dsh-Go/tree/288234ae52fdfcfc2b0a0388763c371d0b09ea7d) 为固定上游，承接 [deepclub#444](https://github.com/meyaomiao/deepclub/issues/444)（方案）、[deepclub#480](https://github.com/meyaomiao/deepclub/issues/480)（扫码连接电脑）和 [mobile#1](https://github.com/meyaomiao/deepclub-mobile/issues/1)（首版实现）。UI 改动必须同时满足 [UI 检查规范](ui-review.md)。

本文中「已上线」「已实现」「待实现」分开写；模拟器和合成环境结果不等于真机或生产验收。

## 1. 定位

深云移动端由**两个 App** 组成，分别发布，外壳、登录和交互保持一致（用户 2026-11-13 决定）：

| 平台 | 基础 | 能力 | 分发 |
|---|---|---|---|
| Android | [DSH Go](https://github.com/ccch1mneyyy/dsh-Go)（Flutter，AGPL-3.0） | 手机本机 Agent + 连接电脑 + 账户 | 官网 APK |
| iOS | [Whaleness / dsh-mobile](https://github.com/Clarklevis1995/dsh-mobile)（SwiftUI + KMP，MIT） | 只连接电脑 + 账户 | App Store / TestFlight |

两端共同的角色：

| 角色 | 说明 |
|---|---|
| 电脑的遥控器 | 扫 DeepClub 桌面端的二维码配对，读取电脑已有项目和对话，让 Agent 在电脑上执行 |
| 深云账户入口 | 登录、设备、公告、更新（iOS 不含充值，见 §7.4） |
| 手机本机 Agent（仅 Android） | App 内置 DSH 引擎，登录深云后自动配置模型与工具，在手机上执行任务 |

用户只需要记住一件事：**登录深云；要用电脑就扫一下码。** 不填写接口地址、API Key、模型、SSH 地址或端口。两个 App 都叫 **DeepClub**（用户决定），每个平台的用户只会看到一个 DeepClub App。

不做：iOS 本机运行 Agent、无 Agent 能力的轻量聊天版。

## 2. 现状（2026-11-13）

| 范围 | 状态 | 依据 |
|---|---|---|
| 品牌：`net.deepclub.agent`、图标/主题、受限素材移除 | 已实现，未合并；显示名仍为「深云 Agent」，需改为 DeepClub（P0） | PR #2 |
| 系统浏览器 PKCE 登录、密码 + 2FA 备用、设备会话安全存储 | 已实现；模拟器验证 | PR #2，[验证记录](verification.md) |
| `agent-config` 同步模型与工具；保留用户模型、思考程度 | 已实现；真实 DSH RPC 验证 | 同上 |
| 后端：设备销售授权、agent-config、网页授权、续期、撤销 | **已上线生产** `5cc2863`（2026-11-13 18:09 UTC） | [deepclub#477](https://github.com/meyaomiao/deepclub/issues/477) |
| 生产网页授权 → 兑换 → 33 个授权模型 / 7 个渠道 → 撤销后双凭据 401 | 生产实测通过（临时验证设备，已撤销） | 同上 |
| 真机 / 国产 ROM 上的回调、本机引擎、后台保活 | **未验证** | — |
| 扫码连接电脑、读取电脑已有项目 | **未实现**（Android App 只开放 SSH） | deepclub#480 |
| iOS 远程 App（基于 Whaleness） | **未开始**；桌面端已内置其连接协议 | §7 |
| 登录后加载页布局 | **有缺陷**：多个进度条叠在一起 | [UI 检查规范 §6](ui-review.md#6-已确认的现有问题) |

旧服务签发的设备 Key 没有销售权限。已安装旧版的手机需要在账号页退出，重新授权一次。

## 3. 信息架构与流程

### 3.1 运行位置

App 顶部（抽屉头部 / 宽屏侧栏顶部）常驻**运行位置切换**：

- **此手机**：本机 DSH 引擎。
- **我的电脑**（可多台）：已配对的电脑，显示名称和连接状态。
- **+ 连接电脑**：打开扫码。

当前位置在聊天顶栏用一个胶囊表示（「此手机」/「MacBook · 已连接」）。切换位置不会把一台主机的对话、审批或设置带到另一台。iOS 没有「此手机」，只列已配对的电脑和「+ 连接电脑」，其余位置与样式相同。

### 3.2 首次使用

```
打开 App
  ├─ 后台：解压本机运行环境（约 1 GB）
  └─ 前台：登录深云（系统浏览器授权，回到 App）
        └─ 自动：申领设备 Key → 同步 agent-config → 写入引擎 → 进入首页
首页空状态：开始对话；次要入口「连接电脑」
```

- 首次使用只有「登录」一个必要步骤；外观、权限在用到时再处理。
- 准备过程只显示**一个**阶段式进度（见 UI 规范 §2），不出现多个独立转圈或进度条。
- **只连接电脑（用户决定：允许）**：登录页提供次要入口「只用来连接电脑」。选择后不解压本机运行环境（节省约 1 GB 存储），登录后直接进入扫码；首页和设置里显示「本机引擎未安装」，可以随时安装。
  - 运行环境目前打包在 APK 内，跳过解压只节省存储，APK 仍约 211 MB。要缩小安装包，需要把运行环境改成按需下载，列为后续可选优化。
  - 默认路径不变：不点这个入口，登录期间照常后台解压。

### 3.3 主界面

沿用上游五种页面骨架（[page-design.md](https://github.com/ccch1mneyyy/dsh-Go/blob/288234ae52fdfcfc2b0a0388763c371d0b09ea7d/docs/design/page-design.md)）：聊天、对话抽屉、工作区、文件、终端、设置。账号页并入设置首页的概览卡（账号 / 引擎），不再使用独立的原始 `Scaffold + AppBar` 页面。

## 4. 本机 Agent：账号与模型（已实现部分的约定）

- **凭据**：设备 `session_token` 放 Android 安全存储；设备 API Key 只写本机引擎凭据（引用名 `DEEPCLUB_API_KEY`）。两者按设备生成，退出或撤销时服务端同时停用，App 清除引擎中的 Key。
- **模型目录**：登录后、每次启动、收到 401/403 时同步 `GET /api/client/agent-config`；`revision` 不变不重写。只有首次且没有用户选择时采用推荐模型；之后保留已有会话模型、思考程度和自定义渠道。
- **工具**：深云媒体与 embedding 工具按授权目录启用；付费请求走审批，收费 POST 不自动重试。
- **关闭项**：DeepSeek 账号引导、匿名遥测、论坛/市场、托管分享、桌宠/伙伴、未接代理的联网搜索、授权不明的手机操控。
- **边界**：自动配置只作用于本机引擎。`LocalDeepClubEngine` 构造时拒绝远程连接（[agent_config.dart](../overlay/new/app/lib/deepclub/agent_config.dart)），远程模式绝不把手机的 Key 或默认模型写到电脑。

## 5. 扫码连接电脑（待实现，deepclub#480）

### 5.1 用户流程

1. 电脑：DeepClub 桌面端左下角「连接手机」，弹层直接显示二维码，并列出已连接设备。**同一个二维码 Android 和 iOS 都能扫。**
2. 手机：首页或运行位置菜单点「扫一扫连接电脑」；也支持相册识别和粘贴配对码。用系统相机扫码时，`https://deepclub.net/pair#…` 通用链接直接唤起已安装的 App；未安装时打开深云网页，按平台给出 Android / iOS 下载。
3. **扫码即配对，电脑端不需要点确认**（用户决定）。前提是手机和电脑登录同一个深云账号（§5.3）。配对成功后手机保存这台电脑，显示电脑上的项目和对话；电脑弹出「已连接 iPhone 15」通知，可一键撤销。
4. 之后打开 App 自动重连，不再扫码。电脑离线时显示「电脑离线」，不影响 Android 的「此手机」。
5. 远程模式暂不加指纹或面容解锁（用户决定）。

### 5.2 二维码内容

二维码内容为 `https://deepclub.net/pair#<payload>`。`payload` 是无填充 base64url JSON，在 Whaleness 现有 version 2 格式上**只加字段、不改原字段**；放在 `#` 后，不会进入服务器访问日志。

| 字段 | 来源 | 说明 |
|---|---|---|
| `version` | 原有 | 固定 2 |
| `gatewayId` | 原有 | 电脑网关标识（UUIDv4） |
| `gatewayName` | 原有 | 电脑显示名 |
| `publicUrl` / `endpoints` | 原有 | 局域网地址与深云中转地址 `wss://deepclub.net/ws/mobile/<gatewayId>` |
| `pairingCode` | 原有 | 256-bit 一次性配对码 |
| `expiresAt` | 原有 | 过期时间（建议 2–5 分钟） |
| `protocols` | 新增 | 电脑支持的连接协议，如 `["dsh-mobile-v1","deepclub-native-v1"]` |
| `hostKey` | 新增 | 电脑长期公钥指纹，用于钉扎与端到端加密 |

iOS 原解析器用 Codable 解码，会忽略新增字段；深云 iOS 版只需额外接受 `https://deepclub.net/pair#` 前缀。二维码**不含** API Key、账号 token、账号 ID 或长期设备凭据。过期、已使用、指纹不符或账号不一致一律拒绝。

### 5.3 传输与安全

**原则：每个 App 继续说自己上游的协议，桌面网关同时支持两种。** 不强行把一端改写成另一端的协议。

| App | 协议 | 桌面端现状 |
|---|---|---|
| iOS（Whaleness 基础） | `dsh-mobile-v1` 业务协议 | 已内置（Whaleness 网关），可直接复用 |
| Android（DSH Go 基础） | `deepclub-native-v1`：DSH 原生 RPC + mux 隧道 | 待新增 |

两种协议共用同一套配对、二维码、设备管理、局域网监听和深云中转；手机按二维码中的 `protocols` 选择。

**同一深云账号（用户决定，强制）**：

- 两个 App 都必须先登录深云。配对时，手机向深云服务端申请一个短效账号断言（绑定 `gatewayId`、设备 ID，有效期约 2 分钟），随配对请求发给电脑。电脑用自己的深云凭据向服务端核验，**账号不同则拒绝配对**。局域网配对同样需要这一步，因此首次配对时电脑和手机都要能访问深云。
- 经深云中转的每次连接，中转同时核验手机的设备会话和电脑的账号属于同一用户。
- 手机退出登录、设备在网页被撤销或电脑更换账号后，已配对的远程访问随之失效，需要重新扫码。
- 电脑目前用深云 API Key 注册中转，服务端可由 Key 解析出所属用户，不要求电脑先改成账号登录。

以下约定针对 Android 的原生隧道：

- 移动端上层（会话、流式消息、文件、终端、模型、审批）都基于 `DshCarrier.call(endpoint,args)` 和 `DshMuxLink`（open/item/end/error/cancel、`$events` ready/clientId）。只需新增一个薄 carrier，就能复用全部现有界面。见 [carrier.dart](https://github.com/ccch1mneyyy/dsh-Go/blob/288234ae52fdfcfc2b0a0388763c371d0b09ea7d/packages/dsh_client/lib/src/carrier.dart#L35-L109)。
- 桌面网关新增原生子协议（暂名 `deepclub-native-v1`），在已鉴权设备连接上转发 Typert 调用与 mux 流，保留流取消、generation、断线 resync 和多端审批「先完成者生效」。
- **端点白名单，默认拒绝**：开放 `session/*`、`workspace/*`、`directoryPicker/list|createDirectory`、`workspaceFiles/*`、`fileReferences/list`、`terminal/*`、`commands/*`、审批与提问回复；拒绝 `credentials/*`、渠道 Key 写入及其他本机管理操作。未知端点返回 `METHOD_NOT_ALLOWED`。
- **端到端加密**：深云中转是透明 WSS 转发，服务器能看到帧。会话内容应在手机与电脑之间加密（优先复用 `dsh_remote` 已有的 Noise IK 实现，用二维码里的 `hostKey` 钉扎），中转只看到密文。
- **路由**：同一网络优先局域网直连；否则走深云中转。WebRTC P2P 作为后续优化，不阻塞首版。
- **凭据**：每台手机在每台电脑上有独立长期设备 token，存 Android Keystore（`SecureSecretStore`）；主机列表只存非敏感元数据。电脑撤销设备后，手机停止重连并提示重新扫码。
- **服务端**：中转当前只回应 `dsh-mobile-v1` 子协议（[mobile_tunnel.go](https://github.com/meyaomiao/deepclub/blob/5cc28633533a4b07707c4029e04625d0b4aeb3a4/controller/mobile_tunnel.go#L547-L553)），需要增加新子协议的协商，以及同账号核验（账号断言签发与核验接口、中转连接核验）；其余注册、限流、透传逻辑复用。
- **iOS 首版不要求端到端加密（用户决定）**：`dsh-mobile-v1` 经中转时只用 TLS，中转服务端技术上可见内容；中转不记录、不落盘帧内容。Android 原生隧道的端到端加密仍在 P4 评估，可与 iOS 保持一致。

### 5.4 设置归属

| 内容 | 归属 |
|---|---|
| 远程对话、项目、文件、终端 | 电脑 |
| 远程模型、思考程度、权限策略、审批 | 电脑上的 DSH（手机只是发起和回答） |
| 电脑的模型 Key | 只在电脑，永不下发到手机 |
| 本机引擎设置、手机外观、通知 | 手机 |
| 设备 token、主机列表 | 手机（token 在 Keystore） |

### 5.5 版本兼容

手机和电脑的 DSH 版本可能不同。连接时协商协议版本、DSH 版本和能力集；手机对未知版本只开放已知安全的只读与对话能力，**不伪造版本号**。现有交互激活只认 `0.2.2-alpha.2` / `0.2.2-rc.1`（[session_activation.dart](https://github.com/ccch1mneyyy/dsh-Go/blob/288234ae52fdfcfc2b0a0388763c371d0b09ea7d/packages/dsh_client/lib/src/session_activation.dart#L91-L110)），桌面端升级时需同步更新兼容表。

## 6. 读取电脑已有项目（待实现，接口已存在）

连接电脑后：

| 用户看到 | 使用的接口 |
|---|---|
| 电脑上已加入 DeepClub 的项目（工作区）及各自的对话 | `workspace/follow`（实时）、`session/list` |
| 浏览电脑磁盘，把已有项目文件夹加入工作区 | `directoryPicker/list`、`workspace/create` |
| 项目文件树、代码阅读、搜索 | `workspaceFiles/list|read|readBytes|changes`、`fileReferences/list` |
| 在项目目录里继续对话、跑命令和测试 | `session/create`（`workspaceId`/`cwd`）、`terminal/*` |

上表是 Android（原生协议）。iOS 用 Whaleness 协议的对应能力：`sessions`、`history`、`workspace-create`、`directory-create`、目录浏览、`file-list`、`file-resolve`、`file-download-*`。项目列表、浏览电脑目录、加入已有项目、看文件和继续对话两端都有；**iOS 没有终端**。

约定：

- **加入项目只登记目录**，不复制、不上传、不重新生成项目文件；未提交的改动同样可见。
- 代码修改由 Agent 在电脑上执行并走审批；首版手机端只读浏览文件，不提供手动编辑器。
- 大文件分页读取（每页至多 5000 行 / 2 MiB），二进制只给下载或预览。
- **系统权限**：macOS 上 DeepClub 桌面端读取「文稿」「桌面」「下载」需要用户在电脑上授权一次；未授权时手机显示「需要在电脑上允许访问此文件夹」，而不是空列表。
- **Windows 路径**：`C:\…` 形式路径的显示、拼接和面包屑需要专门测试（`resolveSessionPath` 对 Windows 路径原样返回）。
- 手机和电脑同时操作同一对话时：消息排队，审批任一端先完成即生效，另一端同步收起。

## 7. iOS 端（基于 Whaleness）

### 7.1 为什么用 Whaleness

- [dsh-mobile](https://github.com/Clarklevis1995/dsh-mobile)（2026-11-13 核对 `f86f005`）为 MIT 许可，原生 SwiftUI + KMP 共享层，iOS 16.1+，持续维护。可以改品牌、改包名后发布，只需保留原版权和许可声明。
- 它的协议正是 DeepClub 桌面端已经内置的 Whaleness 网关协议（`dsh-mobile-v1`），扫码、局域网、深云中转都已打通。iOS 远程首版不需要新写协议。
- 已具备：工作区与对话、目录浏览与加入已有项目、文件列表与下载、流式回复与执行轨迹、提问与审批、模型与权限切换、语音输入（需电脑端官方语音插件）、定时任务。

### 7.2 改造范围

与 Android 相同，采用独立改造层仓库（暂名 `deepclub-ios`）：固定上游提交，保存补丁与替换资产，构建脚本拒绝上游漂移。

| 项目 | 改法 |
|---|---|
| 名称、图标、启动画面、主题 | **DeepClub**，与 Android 同一套品牌资产与色板 |
| Bundle ID | 新的 `net.deepclub.*`（如 `net.deepclub.remote`），含分享、动作扩展与实时活动组件 |
| 文案 | `Info.plist` 和扩展中的「Whaleness」、DeepSeek Harness 字样替换；保留「基于 dsh-mobile 修改」声明 |
| 深云登录 | 新增：`ASWebAuthenticationSession` + PKCE，与 Android 走同一授权页；设备会话放 Keychain |
| 扫码 | 解析器额外接受 `https://deepclub.net/pair#` 前缀；配对时附带账号断言（§5.3）；接入通用链接 |
| 外部服务 | 核对并关闭或替换原作者的下载、推送、统计等服务（与 Android 首版同样审计） |
| 不带入 | 上游 Android 工程（Android 用 DSH Go 版）、原作者推广与社群入口 |

后端配套：iOS 只遥控电脑，不需要模型 API Key。授权接口需区分客户端类型：iOS 换取的只有设备会话，**不申领设备 Key**，减少凭据暴露面。

### 7.3 两个 App 怎么做到「像一个」

代码不共享（Flutter 与 SwiftUI），一致性靠共同规范：

- **同一品牌与设计规范**：[UI 检查规范](ui-review.md)对两端都适用；平台控件各自原生实现，但颜色、字号阶梯、间距、图标风格、文案和状态用词相同。
- **同一登录**：都用系统浏览器打开同一个深云授权页，确认后回到 App；页面、按钮文案和失败提示一致。
- **同一扫码**：同一个电脑二维码、同样的扫码页布局、同样的「相册识别」「粘贴配对码」入口。
- **同一连接状态**：电脑列表、六种连接状态和撤销提示措辞相同。
- **一个下载页**：`deepclub.net/download/mobile` 按访问设备给出 Android APK 或 App Store；扫码未安装时落到同一页面。

### 7.4 App Store 注意事项

- 需要 Apple Developer Program 账号；macOS 公证所用的团队账号同样可以发布 iOS，需确认团队角色。
- **充值**：App 内不能放外部充值按钮或链接（数字内容须走应用内购买）。iOS 版只显示余额，不提供充值入口。
- **第三方登录（用户决定：不加通过 Apple 登录）**：iOS 发起的授权，授权页只显示 DeepClub 账号密码、两步验证和 Passkey，**隐藏** GitHub、Discord、OIDC 等第三方登录，避免审核要求同时提供 Apple 登录。
  - 授权页需按客户端类型区分显示，Android 和网页不受影响。
  - 只用第三方登录注册、没有密码的用户，需要先在网页上设置密码或添加 Passkey，再登录 iOS 版；iOS 授权页给出这条提示和网页链接。
- 不在 App 内开放注册，则不必在 App 内提供注销账号；若以后开放注册，需提供 App 内注销入口。
- 远程执行发生在用户自己的电脑上，App 本身不下载或执行代码。审核说明中写清这一点，并提供测试账号和一台可连接的测试电脑。
- 先走 TestFlight 内部测试，再外部测试（需 Beta 审核），最后上架。

### 7.5 桌面端调整

- 左下角入口从「Whaleness 移动设备」改为「连接手机」，去掉 Whaleness 品牌与原 App 下载链接，改为深云两个 App 的下载。
- 保留 Whaleness 网关作为 iOS 的连接协议；新增 Android 原生协议。原 Whaleness App 已配对的设备在过渡期继续可用，新配对引导到深云 App。

## 8. 品牌与外部服务

Android 已在首版落实，iOS 按同一标准执行，后续改动不得回退：

- 名称、包名、深链 `deepclub://`、图标、启动画面、主题色（朱红 `#D94A38`、石墨 `#29292D`、冷白 `#F4F4F5`）。主色只给可点的主操作和品牌时刻。
- 两个 App 的显示名在所有系统语言下都是 **DeepClub**；Android 首版的「深云 Agent」需改名。
- 应用更新：Android 走深云 `/api/client/site`；iOS 走 App Store。遥测、托管分享、论坛、插件市场、DeepSeek 平台入口及原作者服务关闭。
- 保留上游声明与许可义务：Android「基于 DSH Go 修改」、AGPL 及第三方义务，原受限素材与 Phase 衍生代码不进 APK；iOS「基于 dsh-mobile 修改」、MIT 版权声明及依赖许可（SwiftMath、swift-markdown-ui 等）。两端均注明「非 DeepSeek 官方产品」。

## 9. 任务拆分与阶段

| 阶段 | 仓库 | 内容 |
|---|---|---|
| **P0 Android 首版收尾** | mobile | 显示名改为 DeepClub；修复登录后加载页（UI 规范 §6）；真机安装、浏览器回调、本机引擎进首页、退出与撤销；合并 PR #2；内测 APK |
| **P1 同账号配对与统一二维码** | deepclub、desktop | 账号断言签发与核验、中转同账号核验、iOS 客户端类型（不申领 Key、授权页隐藏第三方登录）；桌面「连接手机」弹层与统一二维码；`/pair` 落地页与下载页 |
| **P2 iOS 远程首版** | ios（新）、desktop | 改造层仓库、品牌与 Bundle ID、深云登录、扫码前缀与账号断言、外部服务审计；TestFlight 内部测试 |
| **P3 Android 远程** | desktop、mobile | 原生子协议与端点白名单；`HostKind.gateway`、扫码/相册/粘贴、薄 carrier、Keystore token、运行位置切换；电脑项目浏览；「只用来连接电脑」入口与稍后安装本机引擎 |
| **P4 异地与加固** | deepclub、desktop、两端 App | 中转新子协议；端到端加密与主机钉扎；撤销即断；断线重连与 resync；macOS 文件夹授权提示；Windows 路径 |
| **P5 上架与收尾** | ios、desktop | App Store 审核与上架；桌面去掉 Whaleness 品牌入口；原 Whaleness 已配对设备迁移 |

iOS 远程依赖的协议在桌面端已经存在，所以 P2 可能比 P3 更早交付。每个阶段一张执行单、一个隔离分支、一个 Draft PR；生产发布、APK 分发和 App Store 提交分别需要用户授权。

## 10. 验收矩阵

按环境分别记录，不互相代替：单元/合成 → 模拟器 → 真机同 Wi-Fi → 真机跨公网 → 生产。R 系列 Android、iOS 各验一次。

| 编号 | 检查项 | 最低环境 |
|---|---|---|
| L1 | Android 安装后只登录一次即进入有模型的首页，不填任何地址或 Key | 真机 |
| L2 | 退出 / 网页撤销后，会话与模型 Key 均 401，引擎中 Key 清除 | 真机 + 生产 |
| L3 | 重启后同步配置；revision 不变不重写；用户模型与思考档不被覆盖 | 模拟器 |
| L4 | 登录后加载页符合 UI 规范（截图矩阵全部通过） | 真机截图 |
| L5 | 选择「只用来连接电脑」后不解压运行环境；之后可在设置中安装本机引擎并正常使用 | 真机 |
| R1 | 桌面二维码 → 扫码即配对（电脑无需确认）→ 进入电脑项目，之后启动自动重连 | 真机同 Wi-Fi |
| R2 | 二维码过期、重放、指纹不符、已撤销 token 均被拒绝 | 合成 |
| R3 | **不同深云账号的手机扫码被拒绝**；手机退出或设备被撤销后远程访问失效 | 合成 + 生产 |
| R4 | 跨公网经深云中转可用；加密方案与 §5.3 定案一致 | 真机跨公网 |
| R5 | 电脑已有项目：列表、加入已有目录、文件浏览、继续已有对话 | 真机 |
| R6 | 流式、停止、断网重连正确；审批任一端完成后另一端收起 | 真机 |
| R7 | Android 切换运行位置不串对话、审批、模型或凭据；手机自动配置不写电脑 | 合成 + 真机 |
| R8 | macOS 与 Windows 桌面各验证一次 R1、R5 | 真机 |
| I1 | iOS 登录不申领模型 Key；授权页无第三方登录；App 内无充值入口；无原作者服务请求 | 真机 + 抓包 |
| I2 | 系统相机扫码：已安装唤起 App，未安装落到下载页 | 真机 |
| W1 | 桌面去掉 Whaleness 品牌入口前：两端 R 系列通过，并有回退路径 | — |

## 11. 风险

- **手机丢失 = 电脑可被操作**：电脑端「已连接设备」可一键撤销，网页撤销手机设备也会让远程失效。远程模式暂不加生物识别锁（用户决定）。
- **扫码无需确认**：靠一次性短效码 + 同账号核验 + 电脑通知可撤销兜底；二维码被他人拍下且对方登录同一账号的情况，与账号本身被盗等价。
- **Agent 能读到 Android 引擎里的 Key**：设备专属 Key、可撤销、单设备限额与告警。
- **两个上游、两种协议**：DSH Go 与 dsh-mobile 都更新频繁，桌面网关同时维护两种协议。两端各自固定上游版本，桌面升级时回归两端 R 系列。
- **App Store 审核**：充值、第三方登录和远程执行说明见 §7.4，被拒会推迟 iOS 上架。
- **iOS 后台**：退到后台后 WebSocket 会被系统挂起，长任务完成提醒需要推送；原作者推送服务不可直接沿用，深云推送放后续阶段。
- **后台限制**：国产 ROM 会杀后台；长任务交给电脑执行更稳。
- **包体**：Android APK 约 211 MB，本机环境约 1 GB。
- **许可**：Android AGPL 源码提供义务及 PRoot（GPL-2.0）等组件义务，Phase 衍生代码不得进入发行物；iOS 保留 MIT 声明。

## 12. 决策记录

已决定（用户，2026-11-13）：

- [x] 两个 App：Android 基于 DSH Go（本机 Agent + 远程），iOS 基于 Whaleness（只远程）；外壳、登录和交互做成一致。
- [x] 两个 App 的名称都是 DeepClub。
- [x] 扫码后电脑端不需要点击确认。
- [x] 手机与电脑必须登录同一深云账号。
- [x] 远程模式暂不加指纹或面容解锁。
- [x] iOS 不加通过 Apple 登录；iOS 授权页隐藏第三方登录。
- [x] iOS 经中转首版不要求端到端加密。
- [x] Android 允许只连接电脑、跳过本机运行环境。
- [x] 不告知 dsh-mobile 原作者；保留其 MIT 版权声明。

待定（实施时确认，不阻塞方案）：

- [ ] iOS Bundle ID（建议 `net.deepclub.remote`）及 Apple 开发者团队角色。
- [ ] Android 运行环境是否改为按需下载以缩小安装包。
