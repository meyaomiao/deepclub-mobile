import { createHash, randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { credentialRef } from '@deepseek-ai/dsh-credentials';
import { defineTool } from '@deepseek-ai/dsh-tools';
import { Config, KEY, TOOLS, baseURL, controlledTestOrigin, modelsFor, selectRequest, snapshot } from './config.js';
import { createClient } from './client.js';
import { createWorkspace, latestUserText } from './files.js';
import { check, fail, safeError, ToolError } from './errors.js';

export { Config };
export const name = 'deepclub-tools';
// user-approval's service key in DSH 0.2.2-rc.1 is "approval".
export const inject = ['credentials', 'tools', 'fs', 'workingDirectory', 'sandboxPolicy', 'jobs', 'approval', 'systemPrompt'];
const ref = credentialRef(KEY);
const digest = value => createHash('sha256').update(value).digest('hex');
const output = {
  schema: { type: 'object', additionalProperties: false, properties: {
    text: { type: 'string', required: true }, files: { type: 'json', required: true },
    meta: { type: 'json', required: true }, job_id: { type: 'string' },
  } },
  render: (_args, value) => [{ type: 'text', text: value.text }],
  presentationMeta: (_args, value) => value.meta ? { 'dsh-go/media': value.meta } : {},
};
function result(request, status, files = [], jobId, error) {
  const meta = request.category === 'embedding' ? null : {
    v: 1, rid: request.rid, kind: request.category, status, ...(jobId ? { job: jobId } : {}),
    items: files, request: { provider: 'deepclub', model: request.model, label: request.model,
      n: request.body.n ?? 1, refs: request.references.length },
    ...(error ? { error: { code: error.code, text: error.message } } : {}),
  };
  return { files, meta, ...(jobId ? { job_id: jobId } : {}), text: error ? error.message
    : status === 'running' ? `视频已进入后台任务 ${jobId}。等待完成通知后调用 deepclub_get_result；不要重新提交。停止等待不代表上游取消或退款。`
      : '深云结果已保存：\n' + files.map(file => `[${file.mime}](<${file.path}>)`).join('\n') };
}
function approvalReason(request) {
  return [
    '本次操作会向深云发送输入并可能产生服务费用。',
    `用户请求原文：${request.userIntent}`,
    `模型：${request.model}；规格：${request.specification ?? '默认'}；端点：${request.endpoint}。`,
    `参数：${JSON.stringify(request.body)}`,
    request.references.length ? '将发送以下用户指定文件的已读取内容：\n' + request.references.join('\n') : '',
    '本次没有可靠的总费用估算；实际收费以服务账单为准。停止等待、超时或失败不代表上游取消或退款。',
  ].filter(Boolean).join('\n');
}

/** Optional loopbackBaseURL/pollMs/timeoutMs are in-process test seams, never settings. */
export function installDeepclubTools(ctx, config, options = {}) {
  const lifetime = new AbortController(), operations = new Set(), results = new Map();
  let registration, closed = false, epoch = 0, pending;
  const track = promise => {
    operations.add(promise);
    void promise.then(() => operations.delete(promise), () => operations.delete(promise));
    return promise;
  };
  function retire() {
    const previous = registration; registration = undefined;
    if (!previous) return;
    previous.abort.abort();
    for (const dispose of previous.disposers.reverse()) dispose();
    results.clear();
  }
  function contextFor(toolName, args, exec, lease, signal) {
    const agent = exec.agent, session = agent?.session;
    if (!session?.id) fail('permission');
    const before = snapshot(config), fingerprint = JSON.stringify(before);
    const selected = selectRequest(before, toolName, args, options.loopbackBaseURL);
    let keyFingerprint;
    function authorize() {
      if (closed || registration !== lease || agent.session !== session) fail('authorization');
      ctx.fiber.assertActive(); agent.ctx.fiber.assertActive();
      if (JSON.stringify(snapshot(config)) !== fingerprint) fail('authorization');
      // Re-evaluate model, endpoint and specification on every network/file operation.
      selectRequest(snapshot(config), toolName, args, options.loopbackBaseURL);
    }
    async function validate() { check(signal); authorize(); }
    async function resolveKey(allowStopped = false) {
      if (!allowStopped) check(signal);
      authorize();
      const credential = await ctx.credentials.resolve(ref);
      authorize();
      if (!allowStopped) check(signal);
      if (typeof credential?.value !== 'string' || !credential.value.trim()) fail('credential');
      const hash = digest(credential.value);
      if (keyFingerprint !== undefined && hash !== keyFingerprint) fail('credential');
      keyFingerprint = hash;
      return credential.value;
    }
    return { ...options, selected, session, signal, validate, resolveKey,
      async checkAccess() { await resolveKey(true); } };
  }
  async function prepare(toolName, args, exec, lease, signal) {
    const context = contextFor(toolName, args, exec, lease, signal);
    const request = { ...context.selected, rid: 'm_' + randomUUID() };
    const userText = latestUserText(context.session);
    if (!userText.includes(request.userIntent)) fail('permission');
    await context.resolveKey();
    const workspace = await createWorkspace(ctx, { ...exec, signal }, async () => { await context.resolveKey(); });
    const references = await workspace.references(request.references, userText);
    await workspace.preflight();
    let approval;
    try { approval = await ctx.approval.request({ agent: exec.agent, toolName, callId: exec.callId,
      reason: approvalReason(request), signal: exec.signal }); } catch { fail('approval'); }
    if (approval !== 'allowed-once') fail('approval');
    check(exec.signal);
    await context.resolveKey();
    await workspace.validateReferences(references);
    return { request, context, workspace, references, client: createClient(request, context) };
  }
  function capability(toolName, catalog, lease) {
    const models = modelsFor(catalog, toolName);
    if (!models.length) return;
    const category = TOOLS[toolName].category;
    const parameters = {
      model: { type: 'string', required: true, enum: models.map(m => m.id) },
      user_intent: { type: 'string', required: true, description: '逐字引用当前用户明确要求此付费操作的一段原文；工具将再次请求主机审批。' },
      specification: { type: 'string', description: '所选模型的授权规格 key；有多个规格时必须指定。' },
      ...(category === 'embedding' ? {
        input: { type: 'json', required: true, description: '用户要求嵌入的字符串或字符串数组；向量保存为工作区 JSON。' },
      } : {
        prompt: { type: 'string', required: true, description: '完整生成或编辑要求。' },
        size: { type: 'string', description: '仅可选择该规格公布的尺寸；未指定时使用该规格默认值。' },
        quality: { type: 'string', description: '仅可使用所选规格的 quality。' },
        ratio: { type: 'string', description: '所选规格允许的 ratio。' },
        n: { type: 'integer', description: '图片张数，默认1，受当前规格与4张上限约束；视频只能1。' },
        ...(category === 'video' ? { seconds: { type: 'integer', description: '所选规格公布的秒数。' } } : {}),
        ...(['deepclub_edit_image', 'deepclub_generate_video'].includes(toolName) ? {
          references: { type: 'array', items: { type: 'string' }, ...(toolName === 'deepclub_edit_image' ? { required: true } : {}),
            description: '当前用户请求里明确指定的工作区图片绝对路径；不接受URL、目录或猜测文件。' },
        } : {}),
      }),
    };
    const tool = defineTool({ name: toolName, parameters, output, timeoutMs: 180000, isConcurrencySafe: () => false,
      description: `${category === 'embedding' ? '按用户要求计算文本嵌入' : category === 'video' ? '按用户要求提交后台视频任务' : toolName === 'deepclub_edit_image' ? '按用户要求编辑图片' : '按用户要求生成图片'}，结果保存到工作区。付费POST绝不自动重试。授权规格：`
        + JSON.stringify(models.map(m => ({ model: m.id, parameters: m.parameters, media: m.media, specifications: m.specifications }))),
      execute(args, exec) {
        return track((async () => {
          const controller = new AbortController();
          const timeout = AbortSignal.timeout(options.timeoutMs ?? (category === 'video' ? 30 * 60000 : 180000));
          const signal = AbortSignal.any([lifetime.signal, lease.abort.signal, controller.signal, timeout,
            ...(category === 'video' ? [] : [exec.signal])]);
          // During approval/preflight, cancelling the initiating tool cancels work too.
          const abortPrepare = () => controller.abort();
          exec.signal.addEventListener('abort', abortPrepare, { once: true });
          let prepared;
          try {
            check(exec.signal);
            prepared = await prepare(toolName, args, exec, lease, signal);
            check(exec.signal);
            if (category === 'video') {
              // Reserve the host job before any paid POST: a full/disabled job
              // registry must never leave a charged request without an owner.
              return startVideo(prepared, exec, controller, lease);
            }
            const files = category === 'embedding'
              ? [await prepared.workspace.saveJSON(await prepared.client.embed())] : [];
            if (category === 'image') for (const asset of await prepared.client.image(prepared.references)) files.push(await prepared.workspace.save(asset));
            return result(prepared.request, 'done', files);
          } catch (error) {
            if (timeout.aborted) throw new ToolError('timeout');
            throw safeError(error, signal);
          } finally { exec.signal.removeEventListener('abort', abortPrepare); }
        })());
      },
    });
    tool.parameters.additionalProperties = false;
    return tool;
  }
  function startVideo({ request, context, client, workspace, references }, exec, controller, lease) {
    const jobId = ctx.jobs.start({ kind: 'deepclub-video', label: request.model, owner: context.session.id,
      toolCall: { callId: exec.callId, rootCallId: exec.rootCallId ?? exec.callId }, outputLimitBytes: 4096,
      run(job) {
        const entry = { session: context.session, lease, value: result(request, 'running', [], job.id), checkAccess: context.checkAccess };
        results.set(job.id, entry);
        const done = track(Promise.resolve().then(async () => {
          try {
            await workspace.validateReferences(references);
            const id = await client.submitVideo(references);
            while (true) {
              const task = await client.videoStatus(id);
              if (task.done) {
                const file = await workspace.save(task.asset);
                await context.validate();
                entry.value = result(request, 'done', [file], job.id);
                return { status: 'completed', result: `视频已保存；调用 deepclub_get_result(job_id="${job.id}") 获取媒体卡片。` };
              }
              job.updateProgress('视频正在排队或生成');
              await delay(options.pollMs ?? 5000, undefined, { signal: context.signal });
            }
          } catch (error) {
            const safe = safeError(error, context.signal);
            entry.value = result(request, 'failed', [], job.id, safe);
            return { status: controller.signal.aborted ? 'killed' : 'failed', detail: safe.message, result: safe.message };
          }
        }));
        return { cancel() { controller.abort(); }, done };
      },
    });
    return results.get(jobId).value;
  }
  function resultTool(lease) {
    const tool = defineTool({ name: 'deepclub_get_result', description: '读取本会话后台视频任务状态与媒体卡片；不接受供应商task id，不创建新任务。使用 job_kill 停止本地等待，上游可能继续收费。',
      parameters: { job_id: { type: 'string', required: true } }, output, isConcurrencySafe: () => true,
      async execute(args, exec) {
        check(exec.signal);
        if (!args || Object.keys(args).some(k => k !== 'job_id')) fail('request');
        const entry = results.get(args.job_id);
        if (!entry || entry.session !== exec.agent?.session || entry.lease !== lease || registration !== lease) fail('permission');
        // A locally killed producer can still expose its honest terminal status.
        if (closed || lease.abort.signal.aborted) fail('authorization');
        try { await entry.checkAccess(); } catch (error) { throw safeError(error, exec.signal); }
        check(exec.signal);
        ctx.jobs.get(args.job_id, exec.agent.session.id);
        return structuredClone(entry.value);
      },
    });
    tool.parameters.additionalProperties = false;
    return tool;
  }
  async function refresh() {
    const mine = ++epoch;
    retire();
    if (closed) return;
    let catalog;
    try { catalog = snapshot(config); baseURL(catalog, options.loopbackBaseURL); } catch { return; }
    const info = await ctx.credentials.describe(ref);
    if (closed || epoch !== mine || !info.configured) return;
    const next = { abort: new AbortController(), disposers: [] };
    registration = next;
    try {
      ctx.fiber.assertActive();
      for (const toolName of Object.keys(TOOLS)) {
        const tool = capability(toolName, catalog, next);
        if (tool) next.disposers.push(ctx.tools.register(tool));
      }
      if (modelsFor(catalog, 'deepclub_generate_video').length) next.disposers.push(ctx.tools.register(resultTool(next)));
      if (next.disposers.length) next.disposers.push(ctx.systemPrompt.section({ name, order: 520, interpolate: false,
        text: 'deepclub_* 工具仅在当前用户明确要求对应生图、改图、视频或嵌入操作时使用。user_intent逐字引用用户原文。只用当前catalog列出的模型、端点和规格。参考图仅用用户指定的工作区文件。付费请求由主机逐次审批；失败或超时禁止自动重试POST。视频返回job后等待完成通知再调用deepclub_get_result；job_kill只停止本地等待，不能声称上游退款或取消成功。不得读取或显示登录Key。' }));
    } catch (error) { retire(); throw error; }
  }
  function scheduleRefresh() {
    pending = refresh();
    void pending.catch(() => retire());
    return pending;
  }
  const stopResults = ctx.jobs.events.subscribe({ owners: 'all' }, event => {
    if (event.type === 'removed') results.delete(event.job.id);
  });
  async function dispose() {
    if (closed) return;
    closed = true; epoch += 1; lifetime.abort(); retire();
    await Promise.allSettled([...operations]);
    results.clear(); await stopResults();
  }
  ctx.effect(() => dispose);
  ctx.on('loader/volatile-update', paths => { if (paths.some(path => path[0] === 'catalog')) void scheduleRefresh(); });
  ctx.on('credentials/reference-updated', updated => { if (String(updated) === KEY) void scheduleRefresh(); });
  const ready = scheduleRefresh();
  return { ready, settled: () => pending, dispose };
}
export async function apply(ctx, config) {
  // Only the trusted debug launcher sets this environment variable. No Config
  // or model argument can enable HTTP, and only these fixed local hosts pass.
  const loopbackBaseURL = controlledTestOrigin(process.env.DEEPCLUB_TEST_ORIGIN);
  await installDeepclubTools(ctx, config, { loopbackBaseURL }).ready;
}
