# 验证记录 / Verification

改造层基于 DSH Go `288234ae52fdfcfc2b0a0388763c371d0b09ea7d`。确切修改文件摘要位于 [source-state.json](../overlay/source-state.json)，运行时输入与配方位于 [upstream.lock.json](../upstream.lock.json) 和构建脚本中。本记录区分已经执行的检查与仍需目标环境的验收。

## 自动检查

| 范围 | 实际结果 |
| --- | --- |
| 完整 Flutter application analyze | `flutter analyze --no-pub`：No issues found |
| 账户、PKCE、模型同步、菜单/分享、更新信息 | `flutter test --no-pub test/deepclub test/deepclub_surface test/brand/site_update_test.dart`：49/49 |
| 模型选择保留 | 真实 DSH settings/credentials RPC：推荐落地；相同 revision 不重写；现有模型与 high 思考档不变；自定义渠道保留 |
| Node 工具、配置归属、清理与本地查看器 | 44/44，无 skip；helper 测试显式指定固定 `DSH_CREDENTIALS_PACKAGE` |
| 实际 Android runtime preset scope | 从固定 runtime 提取的模块运行 4/4；三个 preset 不注册 web_search，web_fetch 实际执行成功 |
| Kotlin helper 清理/进程身份/启动保护 | 独立编译运行 35/35 JVM 测试 |
| GuestSetup 产品语境与 marker | 独立编译运行 9/9 JVM 测试，用户移除 marker 后不覆盖 |
| Android 原生编译 | `compileArm64DebugKotlin` 通过；此检查单独跳过 Flutter 编译任务，不冒充 APK 构建 |
| 本地化与离线查看器 | 72 个 ARB parts、7367 keys；l10n merge/check、viewer generator check 通过 |
| 干净重建 | 新建固定上游 worktree，prepare 后 320 个已修改/新增/删除路径逐个匹配源摘要 |
| 依赖锁 | 原 `app/pubspec.lock` 保持不变 |

完整 Gradle 单测源集中的三份历史测试仍引用本发行版已排除的 phone 实现，因此本轮使用上述确定性 JVM 集合，不声称全量 Gradle tests 通过。原品牌 golden 基线没有被盲目更新；本轮 Flutter 测试是行为测试，不能代表所有字体、ROM 和像素布局。

## Android 实际路径

环境为新建的 Android API36 arm64 隔离模拟器、独立 SQLite、合成账户和 loopback 模拟模型；没有使用真实付费渠道或读取生产凭据。功能验收包为 `0.1.0+11130224` debug；随后追加的文案、菜单、helper 超时回收及 preset 搜索策略通过对应回归，最终交付 APK 的身份/摘要/签名检查由 `verify-apk.py` 单独输出到制品报告。

1. 在 App 点系统浏览器登录，实际网页输入合成账号并明确允许；原生 `deepclub://auth/callback` 返回 App，设备 session/Key 写入与自动模型配置完成。
2. 保留数据升级测试包，已有设备授权保持，未要求用户手填地址、协议、Key 或模型。
3. 在真实 App 发出文件任务。Android 内 DSH 通过真实 Go relay 到 mock 上游，执行实际 `write`，再发第二轮模型请求。文件真实位于 `/root/workspace/deepclub-check.txt`，34 bytes，内容为 `deepclub android local fixture ok\n`，SHA-256 `e2c56893329f4180d6cbbb5536d52410c46e5d57348147da09726ba9e1c1b170`。见 [执行摘要](evidence/file-execution.json)。
4. 实际长流已经开始后按 App 停止按钮。取消经本机 DSH 和 Go relay 传到 mock 上游，记录 `client-cancelled`（278 个片段已发出），App 显示中断。见 [取消摘要](evidence/cancellation-summary.json)。
5. 在 App 手动停止本机引擎后退出账号，触发离线 Node 清理链。实际凭据文档中深云引用消失，后端设备会话已撤销，旧模型 Key 实际 HTTP 401。见 [退出摘要](evidence/offline-logout.json)。

截图均为合成环境，已人工查看，没有 API Key、token、cookie 或签名材料：

| 自动配置首页 | 实际文件工具 |
| --- | --- |
| [查看截图](evidence/configured-home.png) | [查看截图](evidence/file-task.png) |

| 进行中的流 | 离线退出后 |
| --- | --- |
| [查看截图](evidence/streaming.png) | [查看截图](evidence/signed-out.png) |

## 已闭环的问题

- CLI overlay 插入工具会让 settings/mutate 只读：改为启动前幂等注册到用户 web profile，已有配置保留；真实 RPC 与模拟器均已证明修复。
- helper 超时不能直接 SIGKILL PRoot：先向确定属于本 helper 的进程发 SIGQUIT，再核对 PID/启动时间/UID 清理 tracee；用确定性测试证明不扫杀同 rootfs 的其它引擎。
- 根层关闭搜索不能覆盖 preset 自己的工具：改写固定 standard/ptc/cordis 中唯一对应块，逐文件 before/after SHA 校验，实际 scope 验证保留 fetch。
- 退休入口从默认抽屉与宽屏 rail 移除，底层 API/用户数据保留。已撤回模型的 NO_ADAPTER 提示账户恢复，不自动换模型或 Key。
- 测试环境曾因静态目录观察超过一小时而正确返回空 catalog；重新验证 mock 后只刷新 fixture 观察时间，未修改生产新鲜度门禁。另修正 mock 匹配 todo_write 和误把运行时提醒当成人类消息的问题，均不属于产品协议修复。

## 后端配套

[PR #459](https://github.com/meyaomiao/deepclub/pull/459) 的 `f18eefc45321aed3b8f56a82e77896adae8c0c7c` 已通过 [CI](https://github.com/meyaomiao/deepclub/actions/runs/43301301048)。本地六包 Go tests/vet、PKCE/续期 race、前端 75 项测试与构建，以及真实浏览器跨标签身份绑定、原始 state、单/全撤销检查均已完成。它依赖 Draft [PR #450](https://github.com/meyaomiao/deepclub/pull/450)，未生产部署。

## 目标环境边界

尚未验证真实 Android 硬件/国产 ROM 的后台限制、Direct/tawcroot 模式、真实上游付费接口、真实 OAuth/Passkey/微信/2FA 提供商、生产部署与商店分发。模拟器不能替代上游规则要求的真机 PRoot/更新/资源收尾验收；本交付保持内测、Draft 状态。

视频任务句柄不跨引擎重启恢复；参考图为用户指定的工作区路径，不接 attachment ID。旧上游功能矩阵和未经执行的检查没有被记作本首版通过。

## English

The pinned source reconstructs successfully, full Flutter analysis passes, and 49 focused Flutter tests plus 44 Node tests pass. Deterministic JVM checks cover helper process ownership/cleanup and managed instructions. Actual Android emulator acceptance includes browser PKCE, automatic local configuration, real file execution through the Go relay, cancellation propagation and credential removal with the engine stopped.

The provider and accounts are synthetic. APK construction, source/signature verification, emulator behavior and physical-device/production acceptance are separate claims. No paid provider call or production deployment was performed, and the inherited complete golden/Gradle test matrix is not represented as passing.
