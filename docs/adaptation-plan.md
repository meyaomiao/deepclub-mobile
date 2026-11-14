# 深云移动端适配方案

> 2026-11-13 版。以 [DSH Go `288234a`](https://github.com/ccch1mneyyy/dsh-Go/tree/288234ae52fdfcfc2b0a0388763c371d0b09ea7d) 为固定上游，承接 [deepclub#444](https://github.com/meyaomiao/deepclub/issues/444)（方案）、[deepclub#480](https://github.com/meyaomiao/deepclub/issues/480)（扫码连接电脑）和 [mobile#1](https://github.com/meyaomiao/deepclub-mobile/issues/1)（首版实现）。UI 改动必须同时满足 [UI 检查规范](ui-review.md)。

本文中「已上线」「已实现」「待实现」分开写；模拟器和合成环境结果不等于真机或生产验收。

## 1. 定位

深云移动端是深云账号下的 **Android Agent 客户端**，同一个 App 承担三件事：

| 角色 | 说明 |
|---|---|
| 手机本机 Agent | App 内置 DSH 引擎，登录深云后自动配置模型与工具，在手机上执行任务 |
| 电脑的遥控器 | 扫 DeepClub 桌面端的二维码配对，读取电脑已有项目和对话，让 Agent 在电脑上执行 |
| 深云账户入口 | 余额、设备、公告、更新 |

用户只需要记住一件事：**登录深云；要用电脑就扫一下码。** 不填写接口地址、API Key、模型、SSH 地址或端口。

不做：iOS（当前工程无 iOS，本机运行环境不适用 iOS）、上架应用商店（`targetSdk 28` 只能侧载）、无 Agent 能力的轻量聊天版。

## 2. 现状（2026-11-13）

| 范围 | 状态 | 依据 |
|---|---|---|
| 品牌：深云 Agent、`net.deepclub.agent`、图标/主题、受限素材移除 | 已实现，未合并 | PR #2 |
| 系统浏览器 PKCE 登录、密码 + 2FA 备用、设备会话安全存储 | 已实现；模拟器验证 | PR #2，[验证记录](verification.md) |
| `agent-config` 同步模型与工具；保留用户模型、思考程度 | 已实现；真实 DSH RPC 验证 | 同上 |
| 后端：设备销售授权、agent-config、网页授权、续期、撤销 | **已上线生产** `5cc2863`（2026-11-13 18:09 UTC） | [deepclub#477](https://github.com/meyaomiao/deepclub/issues/477) |
| 生产网页授权 → 兑换 → 33 个授权模型 / 7 个渠道 → 撤销后双凭据 401 | 生产实测通过（临时验证设备，已撤销） | 同上 |
| 真机 / 国产 ROM 上的回调、本机引擎、后台保活 | **未验证** | — |
| 扫码连接电脑、读取电脑已有项目 | **未实现**（App 只开放 SSH） | deepclub#480 |
| 登录后加载页布局 | **有缺陷**：多个进度条叠在一起 | [UI 检查规范 §6](ui-review.md#6-已确认的现有问题) |

旧服务签发的设备 Key 没有销售权限。已安装旧版的手机需要在账号页退出，重新授权一次。

## 3. 信息架构与流程

### 3.1 运行位置

App 顶部（抽屉头部 / 宽屏侧栏顶部）常驻**运行位置切换**：

- **此手机**：本机 DSH 引擎。
- **我的电脑**（可多台）：已配对的电脑，显示名称和连接状态。
- **+ 连接电脑**：打开扫码。

当前位置在聊天顶栏用一个胶囊表示（「此手机」/「MacBook · 已连接」）。切换位置不会把一台主机的对话、审批或设置带到另一台。

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
- **待决策**：只想遥控电脑的用户，是否允许跳过本机运行环境下载（节省约 1 GB），在首页提示「本机引擎未安装」并可稍后安装。

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

1. 电脑：DeepClub 桌面端左下角「连接手机」，弹层直接显示二维码，并列出已连接设备。
2. 手机：首页或运行位置菜单点「扫一扫连接电脑」；也支持相册识别和粘贴配对码。系统相机扫码可通过 `deepclub://pair` 直接唤起 App。
3. 配对成功：手机保存这台电脑，切到「我的电脑」，显示电脑上的项目和对话；电脑弹出「已连接 Pixel 8」通知，可一键撤销。
4. 之后打开 App 自动重连，不再扫码。电脑离线时显示「电脑离线」，不影响「此手机」。

### 5.2 二维码内容

版本化的短效一次性载荷（base64url JSON，经 `deepclub://pair?v=1&p=…` 承载）：

| 字段 | 说明 |
|---|---|
| `v` | 载荷版本 |
| `gatewayId` | 电脑网关标识（UUIDv4） |
| `hostName` | 电脑显示名 |
| `hostKey` | 电脑长期公钥指纹，用于钉扎 |
| `endpoints` | 局域网地址与深云中转地址 `wss://deepclub.net/ws/mobile/<gatewayId>` |
| `pairingCode` | 256-bit 一次性配对码 |
| `expiresAt` | 过期时间（建议 2–5 分钟） |

二维码**不含** API Key、账号 token 或长期设备凭据。过期、已使用或签名指纹不符一律拒绝。

### 5.3 传输与安全

**原则：手机继续说 DSH 原生协议，不改写成 Whaleness 业务协议。**

- 移动端上层（会话、流式消息、文件、终端、模型、审批）都基于 `DshCarrier.call(endpoint,args)` 和 `DshMuxLink`（open/item/end/error/cancel、`$events` ready/clientId）。只需新增一个薄 carrier，就能复用全部现有界面。见 [carrier.dart](https://github.com/ccch1mneyyy/dsh-Go/blob/288234ae52fdfcfc2b0a0388763c371d0b09ea7d/packages/dsh_client/lib/src/carrier.dart#L35-L109)。
- 桌面网关新增原生子协议（暂名 `deepclub-native-v1`），在已鉴权设备连接上转发 Typert 调用与 mux 流，保留流取消、generation、断线 resync 和多端审批「先完成者生效」。
- **端点白名单，默认拒绝**：开放 `session/*`、`workspace/*`、`directoryPicker/list|createDirectory`、`workspaceFiles/*`、`fileReferences/list`、`terminal/*`、`commands/*`、审批与提问回复；拒绝 `credentials/*`、渠道 Key 写入及其他本机管理操作。未知端点返回 `METHOD_NOT_ALLOWED`。
- **端到端加密**：深云中转是透明 WSS 转发，服务器能看到帧。会话内容应在手机与电脑之间加密（优先复用 `dsh_remote` 已有的 Noise IK 实现，用二维码里的 `hostKey` 钉扎），中转只看到密文。
- **路由**：同一网络优先局域网直连；否则走深云中转。WebRTC P2P 作为后续优化，不阻塞首版。
- **凭据**：每台手机在每台电脑上有独立长期设备 token，存 Android Keystore（`SecureSecretStore`）；主机列表只存非敏感元数据。电脑撤销设备后，手机停止重连并提示重新扫码。
- **服务端**：中转当前只回应 `dsh-mobile-v1` 子协议（[mobile_tunnel.go](https://github.com/meyaomiao/deepclub/blob/5cc28633533a4b07707c4029e04625d0b4aeb3a4/controller/mobile_tunnel.go#L547-L553)），需要增加新子协议的协商；其余注册、限流、透传逻辑复用。

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

约定：

- **加入项目只登记目录**，不复制、不上传、不重新生成项目文件；未提交的改动同样可见。
- 代码修改由 Agent 在电脑上执行并走审批；首版手机端只读浏览文件，不提供手动编辑器。
- 大文件分页读取（每页至多 5000 行 / 2 MiB），二进制只给下载或预览。
- **系统权限**：macOS 上 DeepClub 桌面端读取「文稿」「桌面」「下载」需要用户在电脑上授权一次；未授权时手机显示「需要在电脑上允许访问此文件夹」，而不是空列表。
- **Windows 路径**：`C:\…` 形式路径的显示、拼接和面包屑需要专门测试（`resolveSessionPath` 对 Windows 路径原样返回）。
- 手机和电脑同时操作同一对话时：消息排队，审批任一端先完成即生效，另一端同步收起。

## 7. 与 Whaleness 的关系

| 阶段 | 桌面端 | 手机端 |
|---|---|---|
| 现在 | 左下角「Whaleness 移动设备」照常工作 | 深云 App 只有 SSH |
| 并存 | 「连接手机」以深云 App 二维码为主；Whaleness 移到「其他连接方式」 | 深云 App 支持扫码 |
| 默认关闭 | 新安装不再显示 Whaleness 入口；已配对设备保留 | — |
| 移除 | 删除 Whaleness 依赖与重复 UI | — |

进入下一阶段的条件见 §9 的 R 系列验收。**待决策**：Whaleness 有 iOS 测试版，深云 App 只有 Android；移除 Whaleness 会让 iOS 用户失去遥控能力，需要先决定 iOS 用户的去向。

## 8. 品牌与外部服务

已在首版落实，后续改动不得回退：

- 名称、包名、深链 `deepclub://`、图标、启动画面、主题色（朱红 `#D94A38`、石墨 `#29292D`、冷白 `#F4F4F5`）。主色只给可点的主操作和品牌时刻。
- 应用更新走深云 `/api/client/site`；遥测、托管分享、论坛、插件市场、DeepSeek 平台入口关闭。
- 保留「基于 DSH Go 修改」「非 DeepSeek 官方产品」声明及 AGPL / 第三方许可义务；原受限素材与 Phase 衍生代码不进 APK。

## 9. 任务拆分与阶段

| 阶段 | 仓库 | 内容 |
|---|---|---|
| **P0 首版收尾** | mobile | 修复登录后加载页（UI 规范 §6）；真机安装、浏览器回调、本机引擎进首页、退出与撤销；合并 PR #2；内测 APK |
| **P1 局域网扫码** | desktop、mobile | 桌面「连接手机」弹层与 v1 二维码；原生子协议 + 端点白名单；手机 `HostKind.gateway`、扫码/相册/粘贴、薄 carrier、Keystore token、运行位置切换 |
| **P2 异地连接** | deepclub、desktop、mobile | 中转子协议协商；端到端加密与主机钉扎；撤销即断；断线重连与 resync |
| **P3 电脑项目** | mobile、desktop | 工作区/对话列表、目录选择、文件浏览体验；macOS 文件夹授权提示；Windows 路径 |
| **P4 Whaleness 迁移** | desktop | 并存 → 默认关闭 → 移除（以 iOS 决策为前提） |

每个阶段一张执行单、一个隔离分支、一个 Draft PR；生产发布和 APK 分发分别需要用户授权。

## 10. 验收矩阵

按环境分别记录，不互相代替：单元/合成 → 模拟器 → 真机同 Wi-Fi → 真机跨公网 → 生产。

| 编号 | 检查项 | 最低环境 |
|---|---|---|
| L1 | 安装后只登录一次即进入有模型的首页，不填任何地址或 Key | 真机 |
| L2 | 退出 / 网页撤销后，会话与模型 Key 均 401，引擎中 Key 清除 | 真机 + 生产 |
| L3 | 重启后同步配置；revision 不变不重写；用户模型与思考档不被覆盖 | 模拟器 |
| L4 | 登录后加载页符合 UI 规范（截图矩阵全部通过） | 真机截图 |
| R1 | 桌面二维码 → 扫码 → 配对 → 进入电脑项目，之后启动自动重连 | 真机同 Wi-Fi |
| R2 | 二维码过期、重放、指纹不符、已撤销 token 均被拒绝 | 合成 |
| R3 | 跨公网经深云中转可用；中转只见密文 | 真机跨公网 |
| R4 | 电脑已有项目：列表、加入已有目录、文件树与代码阅读、继续已有对话 | 真机 |
| R5 | 流式、停止、断网重连、resync 正确；审批任一端完成后另一端收起 | 真机 |
| R6 | 切换运行位置不串对话、审批、模型或凭据；手机自动配置不写电脑 | 合成 + 真机 |
| R7 | macOS 与 Windows 桌面各验证一次 R1、R4 | 真机 |
| W1 | Whaleness 退役前：上述 R 系列通过，并有回退路径 | — |

## 11. 风险

- **手机丢失 = 电脑可被操作**：电脑端「已连接设备」可一键撤销；建议远程模式支持 App 生物识别锁（待决策）。
- **Agent 能读到引擎里的 Key**：设备专属 Key、可撤销、单设备限额与告警。
- **版本耦合**：手机内置 DSH、桌面 DSH、上游 DSH Go 三者版本不同步；以能力协商兜底，并在桌面升级时回归 R 系列。
- **后台限制**：国产 ROM 会杀后台；长任务交给电脑执行更稳。
- **包体**：APK 约 211 MB，本机环境约 1 GB。
- **许可**：AGPL 源码提供义务；PRoot（GPL-2.0）等运行时组件义务；Phase 衍生代码不得进入发行物。

## 12. 待决策

- [ ] 只遥控电脑的用户能否跳过本机运行环境下载。
- [ ] 扫码后是否还需要电脑端点击确认（当前方案：一次性短效码 + 电脑通知可撤销）。
- [ ] 中转是否要求手机与电脑登录同一深云账号。
- [ ] 远程模式是否启用 App 生物识别锁。
- [ ] iOS 用户在 Whaleness 移除后的去向。
