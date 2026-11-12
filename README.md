# 深云 Agent / DeepClub Agent

深云 Android 手机 Agent，基于 [DSH Go](https://github.com/ccch1mneyyy/dsh-Go) 修改。登录深云后，App 自动配置本机 DeepSeek Harness 的模型、凭据和工具，保留任务规划、文件、终端、审批与会话能力，不需要用户填写接口地址或 API Key。

本仓库维护固定上游版本之上的改造层。产品与原作者及 DeepSeek 无隶属关系；代码遵循 [AGPL-3.0](LICENSE)，原版权及第三方声明保留。原品牌、桌宠、Live2D 和许可不适用于本发行版的手机操控实现不进入 APK。来源与修改范围见 [NOTICE.md](NOTICE.md)。

## 已实现

- Android arm64 本机运行；产品名“深云 Agent”、包名 `net.deepclub.agent`，与原客户端及 Whaleness 分开安装。
- 系统浏览器 S256 PKCE 主登录，密码和 2FA 备用；设备会话安全存储、退出/撤销清理、断连后的清理恢复。
- 按服务端 `agent-config` 同步销售模型和工具。只有首次且没有用户选择时采用推荐；后续保留已有会话模型、思考档和自定义渠道。
- 深云媒体与 embedding 工具：按授权目录启用，付费请求走审批，收费 POST 不自动重试，视频轮询为真实本地后台任务。
- 账户余额、设备管理、公告和本站 Android 更新信息；本地分享、文件及终端保留。
- 默认关闭原 DeepSeek 账号引导、遥测、论坛/市场、托管分享、桌宠/伙伴及未接代理的内置联网搜索。`web_fetch` 保留，SSH/Direct 连接电脑放在高级入口。

首版未提供跨设备会话同步、DeepClub/Whaleness 扫码配对、云端音频/重排工具或手机操控。视频任务的客户端句柄不跨引擎重启恢复；取消本地轮询不代表供应商取消或退款。

## 后端要求

运行站点必须包含 [deepclub#446 / PR #450](https://github.com/meyaomiao/deepclub/pull/450) 的设备销售授权与配置接口，以及 [deepclub#452 / PR #459](https://github.com/meyaomiao/deepclub/pull/459) 的网页 PKCE、设备管理、续期和 Android 版本信息。源码/内测包交付不代表这些后端变更已合并或部署。

正式构建固定访问 `https://deepclub.net`。debug 构建可显式使用受限的 loopback/模拟器 origin 进行合成验证；release/profile 忽略该测试定义。

## 重建与验证

详见 [BUILD.md](BUILD.md)。固定输入见 [upstream.lock.json](upstream.lock.json)：DSH Go `288234ae52fdfcfc2b0a0388763c371d0b09ea7d`、Flutter 3.47.7 / Dart 3.13.5、DSH 0.2.2-rc.1。

```sh
python3 scripts/prepare.py --checkout .work/dsh-go
python3 scripts/prepare-runtime.py --checkout .work/dsh-go --apk /path/to/verified-upstream.apk
```

源码层使用文本补丁、带原始摘要的资产替换与新增文件。不会用 Git 二进制反向补丁重新分发原受限美术。构建脚本拒绝上游漂移；运行时输入、三个 preset 配置修改和生成归档均校验摘要。

开发在准备好的源码树进行，审查后用 `scripts/capture-overlay.py` 更新本仓库。所有签名密钥和设备凭据留在仓库外，APK 与构建缓存不提交。

## 验证范围

[验证记录](docs/verification.md)区分本地自动检查、真实 DSH 协议测试、Android 模拟器和未验证环境。模拟器通过真实浏览器授权、本机 PRoot/DSH、真实 Go relay 与受控模型响应，执行了实际文件工具和取消链路；没有真实付费模型调用。

方案索引：[deepclub#444](https://github.com/meyaomiao/deepclub/issues/444)。本仓库执行单：[mobile#1](https://github.com/meyaomiao/deepclub-mobile/issues/1)。

---

## English

DeepClub Agent is an Android adaptation of DSH Go. A DeepClub account provisions a device credential and managed model configuration for the local DeepSeek Harness runtime. It preserves Agent tasks, files, terminals, approvals and conversations, while removing upstream account setup and the retired first-release services listed above.

The application is not an official DeepSeek product. Code is available under AGPL-3.0 with upstream notices preserved. This repository contains the reproducible adaptation layer and pinned inputs; see [BUILD.md](BUILD.md), [NOTICE.md](NOTICE.md) and the [verification record](docs/verification.md).

The backend PRs linked above must be deployed before the production-origin APK can use the new login flow. Current acceptance uses synthetic identities and a local mock provider, not paid upstream calls. Physical-device ROM behavior, production deployment and cross-device/Whaleness pairing remain separate acceptance work.
