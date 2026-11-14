# P0：DeepClub 品牌与准备/账户界面

对应 [mobile#5](https://github.com/meyaomiao/deepclub-mobile/issues/5)，承接 [deepclub#444](https://github.com/meyaomiao/deepclub/issues/444) 更新方案。改造层基于文档提交 `b038e73`，固定 DSH Go `288234ae52fdfcfc2b0a0388763c371d0b09ea7d`。首版 PR #2 与文档 PR #4 的冻结 head 保留。

## 最终行为

- 系统名称、启动/通知、快捷方式默认名与中英文界面均为 **DeepClub**；`net.deepclub.agent`、原签名和既有存储路径保持兼容。
- 登录与运行环境准备继续并行。未登录时运行环境仅有次要文字进度；登录后按「已登录／运行环境／启动引擎／同步模型」显示阶段，只有当前阶段有一个动态指示。
- 失败时仅一个重试入口，正常准备不显示重试；账户收进溢出菜单。准备完成的短暂保留阶段显示静态完成项，然后进入原首页。
- 通过状态监听触发安装/启动，`build` 只渲染。失败重试、清理受阻和主机切换保留恢复路径；账户服务、自动配置及本机凭据归属没有改写。
- 账户 UI 移至 `ui/settings` 并接入设置概览卡，复用 AppPage、SheetGroup、SettingsTile、AppIcons 和 AppSpace。刷新提示位于稳定的操作槽位，账户内容不因进度条插入而上下跳。
- 加载显示延迟 300ms，出现后最少保留 500ms；减少动效时使用静态状态。账号恢复骨架也覆盖短时完成和最低呈现时长。
- 正常退出时显示「正在清除本机登录信息」，只保留一个延迟的局部忙状态；只有真正清理失败且操作已结束，才显示失败说明与重试。该修正来自模拟器实际退出过程，未改清理语义。

## 本地检查

环境：macOS arm64，Flutter 3.47.7 / Dart 3.13.5，JDK17，Android SDK36/NDK28.2。UI 使用 Noto CJK Sans2.004 的真实 Light、Regular、Bold 字重。

| 检查 | 结果 |
| --- | --- |
| Flutter 全应用 analyze、本地化 merge/check | 通过 |
| 账号/PKCE/模型选择保持/清理及界面行为、状态/几何、surface、更新信息 | 通过；扩展集合的唯一旧中文术语断言已同步，并重跑该文件 11/11 |
| 完整 AppIcons 角色/字形/浅深图、架构 import direction | macOS 通过；图标 4/4，架构 3/3 |
| UI 状态矩阵 | 16 状态 × 2 主题 × 2 语言 × 4 尺寸字号 = 256 组合无溢出；键盘与间距另有几何检查；最终 UI 行为/几何 50/50 |
| 真实组件截图 | 初批 240/240 正常比较通过且像素未改；新增清理中 16 张生成通过，清理中/失败合计 32/32 正常比较通过；代表图已人工查看 |
| 品牌锁定图 | 浅深 2/2，人工看图 |
| 原生 Kotlin 编译及既有品牌回归 | GuestSetup 9/9、PictureShortcuts 3/3、LauncherManifest 3/3，共 15/15，无 skip |
| 固定 runtime | 配方/插件输入 revision、原始 APK、归档和原生库摘要一致，bundle gate 通过；本批未改 runtime，复用验证后的相同制品 |
| 干净改造层重建 | 独立固定上游工作树 prepare 与初批 577 项摘要核对通过；CI 现逐项检查完整最终 source-state，含新增清理中截图 |
| 源码导出 | 排除签名/凭据/构建缓存与 Finder 元数据；归档源码和改造层均逐项校验摘要 |

原生回归命令见 [BUILD.md](../BUILD.md)。该命令只缩小本次调用的测试源集，编译真实原生源码；不把这 15 项当作包含被排除手机操控实现的上游全部 Gradle 测试。

macOS 与 Linux 的图标像素基线分别保存，角色和字形守卫在两端都运行。Linux 两张图来自真实 Ubuntu 输出，已人工复核并通过 [43572326620](https://github.com/meyaomiao/deepclub-mobile/actions/runs/43572326620) 的正常比较。清理中状态修正后的最新 CI、APK、完整重建摘要和模拟器结果记录在 [执行单 #5](https://github.com/meyaomiao/deepclub-mobile/issues/5)，未执行项目不从本表推断为已通过。

API36 arm64 专属模拟器已实际完成浏览器确认、App 回调、本机运行环境/DSH启动、模型目录与推荐模型落地、首页、账户详情、刷新和退出；相同 revision 刷新后引擎配置字节不变，退出后合成会话为零、本机 Key 引用移除。模型调用为零。最初合成 fixture 的未支持 compat 字段已修正，未为此修改产品；共享单元 fixture 也校正为真实运行时支持的字段并通过 6/6 配置回归。后续只读 metadata 与签名检查不代替真机使用。

## 截图

以下是生产 Flutter 组件与合成状态的截图，不是真机或生产账号截图。

| 准备运行环境（浅色） | 同步模型（深色） | 完成过渡（浅色） |
| --- | --- | --- |
| [查看](../overlay/new/app/test/deepclub/goldens/macos/extracting_light_zh_phone.png) | [查看](../overlay/new/app/test/deepclub/goldens/macos/syncing_dark_zh_phone.png) | [查看](../overlay/new/app/test/deepclub/goldens/macos/completed_light_zh_phone.png) |

完整矩阵位于 [macOS UI goldens](../overlay/new/app/test/deepclub/goldens/macos/)，显式生成和比较入口为 `test/deepclub/ui_capture.dart`；详情见准备树测试目录中的 `UI.md`。

## UI 规则复核

- [x] 登录、浏览器等待、解压、启动、同步、运行环境失败、同步失败、撤销、重新授权、清理中/失败、完成、账户正常/刷新/离线/零余额有对应状态。
- [x] 同一区域至多一个进度指示，失败至多一个重试；并行解压不叠加第二条进度。
- [x] 阶段切换行高、卡片边界和左右留白稳定；账户刷新不插入页首进度。
- [x] 正常准备只有一个视觉重心，次要账户入口收起；登录与清理操作使用真实业务方法。
- [x] 新界面使用既有组件、间距和图标角色；未添加架构白名单。
- [x] 中文/英文、浅/深色、360×800 @1.0/@1.3/@2.0、840×800、键盘遮挡与减少动效有自动检查。
- [ ] 真机与国产 ROM 的浏览器回调、首次引擎准备、退出/撤销及截图抽查：本轮开始时 ADB 未连接真机，保留验收项。

本阶段不交付扫码协议、同账号断言、iOS App 或 Android「只连接电脑」模式。上述后续仍按 #444 P1–P5 执行。没有覆盖生产服务、发布 APK 下载入口或改用户既有模型/思考选择。
