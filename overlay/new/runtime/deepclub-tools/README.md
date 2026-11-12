# 深云移动工具插件

[English](README.en.md)

适配 DSH `0.2.2-rc.1` / Node 22.19+ 的纯 ESM 插件，无编译步骤。服务端设备 `agent-config` 是模型、端点及规格的唯一授权目录。插件不探测模型能力，不从模型名推断能力，不提供手工 API Key 设置。

## 打包与配置

把本目录的 `src/`、`package.json`、`cordis.patch.yml` 和许可说明放入 `/opt/dsh-go/deepclub-tools/`。该位置由现有 `/opt/dsh-go` 引擎更新事务管理。依赖链接为：

```sh
ln -s /opt/dsh/node_modules /opt/dsh-go/deepclub-tools/node_modules
```

插件入口必须由 profile 持有。Android 普通启动前，把以下唯一插入项幂等合并到 guest `$DSH_HOME/profiles/web/cordis.patch.yml`（本机为 `/root/.dsh/profiles/web/cordis.patch.yml`），放在已有 `deepclub-tools` 配置覆盖项之前，并保留原有 catalog 与其他设置：

```yaml
- insert:
    - id: deepclub-tools
      name: file:///opt/dsh-go/deepclub-tools/src/index.js
```

**禁止用 CLI `--patch` 直接插入此插件**，包括把本包 `cordis.patch.yml` 传给 `dsh web --patch`。DSH 依次应用 bundle、profile、home、CLI 补丁；由 CLI 最后插入的插件无法接收更早的 profile 配置覆盖，`settings/mutate` 会报 `Configuration for "deepclub-tools" is overridden by a home patch or command-line overlay`。迁移时必须移除旧 CLI 插入项；两层同时插入会产生重复 ID。

首次没有 profile 时，可先创建这个 profile patch；DSH 随后初始化官方 `web` profile，并保留已有 patch。已有安装在普通启动前也要检查注册，不能仅在 rootfs 中预置，因为引擎升级保留 `/root` 用户数据。重复启动应保留已存在的正确注册和设置。

本包 `package.json` 的 `dsh.bundle.patch` 仍指向 `cordis.patch.yml`，可供 profile 的 bundle 层引用；该层先于可写 profile 设置层，支持正常反写。使用 bundle 注册时不要再向 profile patch 插入同一 ID。Android 当前采用前述 profile patch 注册。

运行时服务依赖为 `credentials/tools/fs/workingDirectory/sandboxPolicy/jobs/approval/systemPrompt`。DSH `dsh-user-approval` 的注入服务名是 `approval`。默认组合须保留 `dsh-tool-jobs`，否则创建视频任务将拒绝且不发收费 POST。

`Config` 使用 `@deepseek-ai/schemastery`，导出名与 settings namespace 均为 `deepclub-tools`。唯一设置字段 `catalog` 为 volatile，值是完整设备 agent-config：

```json
{"namespace":"deepclub-tools","catalog":{"revision":"...","base_url":"https://deepclub.net","api_key_env":"DEEPCLUB_API_KEY","models":[],"tools":{}}}
```

上例展示命名空间与值关系；`settings/mutate` 的实际写入内容是 `{catalog: <完整agent-config>}`。凭据通过 DSH credentials 读 `DEEPCLUB_API_KEY`，不存入 Config。退出先把 catalog 写为 `{models:[],tools:{}}`，再清 Key；空 `{}` 也安全。配置/Key 事件立即撤销旧工具和任务结果，运行中的任务停止本地等待。每次执行、请求、输出及结果读取还会重新校验当前目录和 Key，防止漏事件时继续使用旧权限。

profile 注册中的 `name` 还必须使用上述 `file:///` URL：DSH Loader 会归一化绝对路径，提前使用规范 URL 可让 ConfigEditor 生成的 override 与原始 entry 匹配。规范 URL 和正确的 profile 层归属缺一不可。

生产服务固定为 `https://deepclub.net`。受控测试可从 JavaScript 调用 `installDeepclubTools(ctx, config, {loopbackBaseURL: 'http://127.0.0.1:PORT'})` 注入一个 origin；Android debug launcher 也可在引擎启动环境中设置 `DEEPCLUB_TEST_ORIGIN=http://10.0.2.2:18453`。仅允许 HTTP 的 `127.0.0.1`、`[::1]` 或模拟器宿主 `10.0.2.2`，不允许路径、凭据、query、fragment。catalog.base_url 只能等于生产站点或这个确切测试 origin。Config 与工具参数没有测试开关；正式启动不设置此环境变量。

## 工具与审批

- `deepclub_generate_image`：`tools.image_generation` 授权、`image` 模型及 `/v1/images/generations` 端点三者交集。
- `deepclub_edit_image`：对应 `image_editing` 与 `/v1/images/edits`，multipart 上传用户指定参考文件。
- `deepclub_generate_video`：对应 `video`；按规格的 `media.video_protocol` 选择 `/v1/videos` multipart 或 `/v1/video/generations` JSON。先占用真实 DSH 后台 job，再执行一次提交、GET 轮询和结果下载。
- `deepclub_get_result`：只接受插件创建的本会话 job id；不接受任意供应商 task id，不再次创建或收费。
- `deepclub_embed`：对应 `embedding` 与 `/v1/embeddings`，向量保存工作区 JSON，工具结果返回文件引用。

首版不注册 audio、rerank 或 web_search。每次调用须给出授权模型；多规格模型必须选 `specification` key。固定尺寸、质量、时长、比例及参考图限制均来自该规格。服务端使用规格公布的参数与 resolution 进行选择，插件不把规格 key 当作请求参数发送。

`user_intent` 必须逐字引用当前会话最新一条真实用户消息中的要求。该检查不代替理解用户意图；系统提示要求模型仅在用户明确要求对应操作时使用工具。所有付费操作再经过 `ctx.approval.request`，只有 `allowed-once` 才提交。审批列出模型、规格、实际输入、文件与收费不确定性。工具不自动批准、不把未知价格报零。POST 不重试，不自动换协议或供应商。

参考图须为当前用户消息中明确指定的工作区绝对路径，且通过引擎文件服务读取；不接受 URL、猜测路径、目录或越界链接。当前版本尚未接入手机图片 attachment ID，用户需在工作区选择文件并把路径加入请求。图片/视频结果带 `dsh-go/media` v1 元数据；不编造未解析的像素尺寸、视频时长或编解码信息。

## 文件和任务边界

输出名固定为工作区内随机 `deepclub-UUID.ext`，模型无输出路径参数。插件使用真实 `fs/write-intent` 与 `fs.writeText(createIfAbsent)` 预检并预留；二进制仅写入经过身份检查的空 inode，使用 `O_NOFOLLOW`，写前后复核会话、工作区、沙箱与父目录。JSON 直接走引擎 `writeText`。二进制适配器只支持同进程主机文件映射；远程或无法往返映射的后端拒绝。它遵循 DSH 可信路径模型，不宣称能抵御拥有同一主机写权限的恶意进程在校验与系统调用之间替换祖先目录。

HTTP 响应有字节上限；API 与下载均禁止重定向。下载链接不附 Bearer，连接时的 DNS 地址检查拒绝内网、loopback 和 link-local；只有构造时明确注入的测试 origin 可以使用 loopback HTTP。错误不回显上游正文、Key 或签名 URL。

job 归属当前 Session 对象和当前授权代次。退出、Key 轮换、配置变化、插件卸载或会话销毁后旧任务不能续查；不持久化恢复记录。`job_kill` 只停止本地工作，不发上游 DELETE，不声称取消或退款。已经提交的生成可能继续并收费。引擎重启后自动恢复尚未实现，不能通过重复调用生成来替代。

## 验证

依赖可使用 rootfs 同版本 node_modules，或为本目录创建指向固定 DSH 测试前缀的临时链接；无需 npm 安装或更新依赖。

```sh
node --test runtime/deepclub-tools/test/*.test.mjs
```

测试使用真实 DSH 0.2.2-rc.1 的文件、Session、Agent registry 与 jobs 实现，以及本地 HTTP 模拟服务和合成凭据。审批答复为受控测试桩；不调用真实付费服务。覆盖授权/端点/规格拒绝、审批拒绝、沙箱与文件路径、multipart、POST不重试、embedding输出、两种视频协议、跨会话任务隔离、取消、退出及配置/凭据刷新。配置回归测试使用真实 profile patch、ConfigEditor、Settings 和 Loader，对照验证 CLI overlay 插入时拒绝写入且保持磁盘和实时配置不变，profile 注册时 namespace 可写、volatile 更新不重建插件、空 catalog 撤销工具；也覆盖缺失旧插件的 disabled 行安全忽略。不执行 I/O 的服务使用桩。

手机安装、PRoot 内加载、原生审批UI和真实付费端点由集成验证负责；桌面 Node 测试不替代这些检查。

## 来源

评估并改写 `meyaomiao/deepclub-desktop@b9719c4` 的 `overlay/new/packages/deepclub/media-tools/src/media-client.ts` 与 `output.ts`（包声明 MIT）：保留受控传输、无POST重试、签名判断和通过引擎预留二进制输出的设计。移除桌面设置/公开目录缓存/默认库存，改为设备授权目录、会话任务与逐次审批；没有复制桌面 UI、Whaleness 或其依赖。另核对 dsh-Go `288234a` 的 dsh-media API/approval 与媒体元数据协议，实现不依赖旧插件。许可全文与署名见 `LICENSE`。
