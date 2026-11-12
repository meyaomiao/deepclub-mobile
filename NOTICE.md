# 来源、许可与修改声明 / Provenance and modifications

本项目是 DeepClub 对 [ccch1mneyyy/dsh-Go](https://github.com/ccch1mneyyy/dsh-Go) 的修改版，不是 DeepSeek 官方产品，与原作者无隶属关系。上游固定提交为 `288234ae52fdfcfc2b0a0388763c371d0b09ea7d`，保留原项目 AGPL-3.0 及第三方声明。重建源码中的 `LICENSE`、`THIRD_PARTY_NOTICES.md`、依赖包内许可证和 App 许可证页均需随发行保留。

DeepClub 修改包括账号与 PKCE 登录、设备凭据管理、服务端模型目录同步、品牌与菜单、深云工具、默认服务收敛，以及所需回归测试。修改版源代码和构建配方由本仓库提供；App 的来源链接可由 `DEEPCLUB_SOURCE_URL` 指向具体构建提交。

## 资产与排除项

- 深云像素标识来自 meyaomiao/deepclub 的现有 `site/brand/deepclub/pixel` 母版，用于本项目构建和品牌展示。它不是上游 DSH Go 图形的改色版本。
- 上游 `ASSETS.md` 标出的 DSH Go 标识、Deepy、鲸娘、鲸尾、桌宠与伙伴素材不在本 APK 资产声明中，Android 图标、通知图标和 Flutter glyph 由深云母版生成。
- Phase 衍生手机操控代码、桌宠/伙伴及特权更新原生源码被编译排除，Manifest 不注册其服务/组件；仅保留返回 unavailable 的自有通道适配。未将上游作者的个别使用许可视作本项目的再分发许可。
- 原版权文字和许可归属仍保留用于来源说明，App 内明确说明相关手机操控实现不包含在本发行版。静态源树中保留的上游文件不等于 APK 已分发该功能。
- 本仓库的资产替换只保存新字节和原摘要，不保存带旧图像数据的 Git 二进制反向补丁。完整源代码导出也排除不参与构建的受限素材和 Phase 源目录。

## 运行时

固定运行时输入是上游 v1.0.15 arm64 APK 内的 Linux runtime 和其声明的四个 Termux 库，输入整体 SHA-256 校验后才提取。没有复用上游 APK 的 DEX、Flutter bundle、签名或品牌图像。原始 Ubuntu、Node、DSH、pnpm、Python、PRoot 和相关库的构建配方、版本/摘要及许可证位于重建树的 `runtime/` 与保留的第三方声明中。

深云重打运行时只增加自有工具，调整明确的默认插件策略，并对固定版本 standard/ptc/cordis preset 的 `tool-web` 关闭 search、保留 fetch；三个输入与输出文件摘要写入运行时清单。用户 profile 的插件注册由原生启动前 helper 完成，配置所有权不放进 CLI overlay。

`runtime/deepclub-tools` 按其目录内 MIT 许可提供，已保留参考的桌面媒体实现来源。其它上游代码保持其各自许可证。

正式对外发布时，应同时提供对应源代码、此改造层与固定上游/第三方源输入，且使用发布者自己管理的签名。开发机生成的内测签名材料没有进入本仓库或源码导出。

## English

This is a modified DSH Go distribution maintained for DeepClub. Upstream AGPL-3.0, dependency licenses and required attribution are retained. The changes cover account authorization, managed credentials/models, branding, tools, service restrictions and regression tests.

Restricted upstream artwork and the Phase-derived phone-control implementation are not distributed in the APK. Replacement artwork uses DeepClub's existing pixel master. Runtime import reuses only checksum-verified Linux runtime assets and the declared Termux libraries, not upstream DEX, Flutter assets or signing material.

The reconstructed source retains upstream notices and build recipes. A distribution must make its corresponding modified source and fixed source inputs available alongside the adaptation layer. Internal signing keys and account credentials are never part of the repository or source export.
