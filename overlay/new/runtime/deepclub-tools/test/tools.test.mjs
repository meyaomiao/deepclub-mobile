import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, realpath, readFile, readdir, rm, writeFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { Context } from '@deepseek-ai/cordis';
import LocalFileSystem from '@deepseek-ai/dsh-fs-local';
import AgentRegistry from '@deepseek-ai/dsh-agent';
import SessionProjections from '@deepseek-ai/dsh-session-projection';
import LocalJobs from '@deepseek-ai/dsh-jobs-local';
import { Session } from '@deepseek-ai/dsh-session';
import { Config, inject, name, installDeepclubTools } from '../src/index.js';
import { selectRequest, baseURL } from '../src/config.js';
import { safeURL } from '../src/client.js';

const KEY = 'synthetic-key-only-not-a-secret';
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=', 'base64');
const MP4 = Buffer.from('000000186674797069736f6d0000020069736f6d69736f32', 'hex');
const price = { currency: 'CNY', unit: 'per_call', quantity: 'call', min: {}, max: {} };
function catalog() {
  return {
    revision: 'fixture-r1', base_url: 'https://deepclub.net', api_key_env: 'DEEPCLUB_API_KEY',
    tools: {
      image_generation: { enabled: true, model_ids: ['fixture-image'] },
      image_editing: { enabled: true, model_ids: ['fixture-image'] },
      video: { enabled: true, model_ids: ['fixture-video', 'fixture-generic'] },
      embedding: { enabled: true, model_ids: ['fixture-embedding'] },
      audio: { enabled: false }, rerank: { enabled: false }, web_search: { enabled: false },
    },
    models: [
      { id: 'fixture-image', category: 'image', endpoints: ['/v1/images/generations', '/v1/images/edits'], price,
        specifications: [{ key: 'square', parameters: { size: '1024x1024' }, media: { resolution: '1K', max_images: 1 } },
          { key: 'wide', parameters: { size: '1536x1024' }, media: { resolution: '1K', max_images: 1 } }] },
      { id: 'fixture-video', category: 'video', endpoints: ['/v1/videos'], parameters: { seconds: '4' },
        media: { video_protocol: 'openai', duration_seconds: 4 }, price },
      { id: 'fixture-generic', category: 'video', endpoints: ['/v1/video/generations'], parameters: { duration: '5' },
        media: { video_protocol: 'generations', duration_seconds: 5, reference_images: true }, price },
      { id: 'fixture-embedding', category: 'embedding', endpoints: ['/v1/embeddings'], price },
    ],
  };
}
const imageArgs = () => ({ model: 'fixture-image', specification: 'square', prompt: 'a cat', user_intent: '生成图片' });
const videoArgs = (model = 'fixture-video') => ({ model, prompt: 'a cat', user_intent: '生成视频' });
const isCode = kind => error => error.code === 'DEEPCLUB_TOOLS_' + kind.toUpperCase();

async function harness(t, options = {}) {
  const temp = await mkdtemp(join(tmpdir(), 'deepclub-tools-test-'));
  const root = await realpath(temp);
  const context = new Context();
  const fibers = [await context.plugin(LocalFileSystem, { cwd: root }), await context.plugin(SessionProjections), await context.plugin(AgentRegistry), await context.plugin(LocalJobs, { maxConcurrentJobsPerOwner: 1 })];
  const detachController = context.jobs.attachController('test-controller');
  const agentFiber = await context.plugin(() => {});
  const session = Session.create('fixture-session-' + root.split('/').at(-1));
  const user = text => session.append('user/message', { role: 'user', id: 'message-' + session.seq, source: { kind: 'user' }, content: [{ type: 'text', text }] }, { surfaceOp: 'append' });
  user('请生成图片，编辑图片，生成视频，并计算嵌入');
  const agent = { id: session.id, session, ctx: agentFiber.ctx, status: 'idle', options: {} };
  context.agents.register(agent);
  const handlers = new Map(), tools = new Map(), effects = [], requests = [], approvals = [];
  let current = catalog(), key = KEY, mode = 'workspace-write', approval = 'allowed-once', responseHook, writeDenied = false, nextCwd = root;
  const pendingRequests = [];
  const server = createServer((req, res) => {
    const work = (async () => {
      const parts = [];
      for await (const part of req) parts.push(part);
      const row = { method: req.method, path: req.url, auth: req.headers.authorization,
        contentType: req.headers['content-type'], body: Buffer.concat(parts).toString('utf8') };
      requests.push(row);
      if (responseHook && await responseHook(row, req, res)) return;
      res.setHeader('Content-Type', 'application/json');
      if (req.url === '/v1/images/generations' || req.url === '/v1/images/edits') res.end(JSON.stringify({ data: [{ b64_json: PNG.toString('base64') }] }));
      else if (req.url === '/v1/embeddings') res.end(JSON.stringify({ data: [{ index: 0, embedding: [0.5, -0.5] }] }));
      else if (req.url === '/v1/videos' && req.method === 'POST') res.end(JSON.stringify({ id: 'task_openai_1', status: 'queued' }));
      else if (req.url === '/v1/videos/task_openai_1') res.end(JSON.stringify({ id: 'task_openai_1', status: 'completed' }));
      else if (req.url === '/v1/videos/task_openai_1/content' || req.url === '/asset.mp4') res.end(MP4);
      else if (req.url === '/v1/video/generations' && req.method === 'POST') res.end(JSON.stringify({ id: 'task_generic_1', task_id: 'task_generic_1', status: 'submitted' }));
      else if (req.url === '/v1/video/generations/task_generic_1') res.end(JSON.stringify({ code: 'success', data: { task_id: 'task_generic_1', status: 'SUCCESS', result_url: base + '/asset.mp4' } }));
      else { res.statusCode = 404; res.end('{}'); }
    })();
    pendingRequests.push(work);
    void work.catch(() => res.destroy());
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = 'http://127.0.0.1:' + server.address().port;
  const ctx = {
    fiber: context.fiber,
    fs: context.fs,
    jobs: context.jobs,
    workingDirectory: { ensure: async () => nextCwd, get: () => nextCwd },
    sandboxPolicy: { resolve: () => ({ mode, workspaceRoot: root }) },
    credentials: { describe: async () => ({ configured: Boolean(key) }), resolve: async () => key ? { value: key } : undefined },
    tools: { register(tool) { assert.ok(!tools.has(tool.name)); tools.set(tool.name, tool); return () => tools.delete(tool.name); } },
    systemPrompt: { section: () => () => {} },
    approval: { async request(value) { approvals.push(value); return typeof approval === 'function' ? approval(value) : approval; } },
    async waterfall(event, target, exec, next) {
      assert.equal(event, 'fs/write-intent');
      if (writeDenied) throw Object.assign(new Error('denied'), { code: 'FS_SANDBOX_DENIED' });
      return next();
    },
    effect(factory) { const dispose = factory(); effects.push(dispose); return dispose; },
    on(event, callback) { handlers.set(event, callback); },
  };
  const config = { catalog: { get: () => current } };
  const installed = installDeepclubTools(ctx, config, { loopbackBaseURL: base, pollMs: 5, timeoutMs: 5000, ...options });
  await installed.ready;
  t.after(async () => {
    await installed.dispose();
    await agentFiber.dispose();
    detachController();
    for (const fiber of fibers.reverse()) await fiber.dispose();
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    await Promise.allSettled(pendingRequests);
    assert.equal(await realpath(root), root);
    assert.ok(root.startsWith(await realpath(tmpdir()) + '/deepclub-tools-test-'));
    await rm(root, { recursive: true });
  });
  const execution = (signal = new AbortController().signal, selectedAgent = agent) => ({ agent: selectedAgent, signal, callId: 'call-test', rootCallId: 'call-test' });
  return {
    root, ctx, tools, requests, approvals, config, installed, context, agent, session, user, base, execution,
    setApproval(value) { approval = value; }, setMode(value) { mode = value; }, denyWrite() { writeDenied = true; }, setCwd(value) { nextCwd = value; },
    onRequest(fn) { responseHook = fn; },
    async setCatalog(value, emit = true) { current = value; if (emit) { handlers.get('loader/volatile-update')([['catalog']]); await installed.settled(); } },
    async setKey(value, emit = true) { key = value; if (emit) { handlers.get('credentials/reference-updated')('DEEPCLUB_API_KEY'); await installed.settled(); } },
    invoke(toolName, args, exec = execution()) { return tools.get(toolName).execute(args, exec); },
    detachController,
  };
}

test('Node ESM plugin uses exact namespace and volatile catalog schema', () => {
  assert.equal(name, 'deepclub-tools');
  assert.ok(inject.includes('approval') && inject.includes('fs') && inject.includes('jobs'));
  assert.deepEqual(Config({}).catalog.get(), {});
  assert.deepEqual(Config({ catalog: catalog() }).catalog.get(), catalog());
  assert.equal(Config.dict.catalog.meta.volatile, true);
  assert.equal(baseURL(catalog()), 'https://deepclub.net');
  for (const url of ['http://deepclub.net', 'https://deepclub.net.evil.test', 'http://127.0.0.1:8080', 'https://user:pw@deepclub.net', 'https://deepclub.net/?token=secret']) {
    assert.throws(() => baseURL({ ...catalog(), base_url: url }), isCode('unsafe_url'));
  }
  assert.throws(() => baseURL(catalog(), 'http://example.test'), isCode('unsafe_url'));
  const debug = 'http://10.0.2.2:18453';
  assert.throws(() => baseURL({ ...catalog(), base_url: debug }), isCode('unsafe_url'));
  assert.equal(baseURL({ ...catalog(), base_url: debug }, debug), debug);
  assert.throws(() => baseURL({ ...catalog(), base_url: 'http://10.0.2.2:9999' }, debug), isCode('unsafe_url'));
  assert.throws(() => baseURL(catalog(), 'http://192.168.1.1:18453'), isCode('unsafe_url'));
  for (const url of ['https://127.0.0.1/file', 'https://[::1]/file', 'https://169.254.169.254/file', 'https://[::ffff:127.0.0.1]/file', 'file:///tmp/file']) assert.throws(() => safeURL(url), isCode('unsafe_url'));
});

test('catalog grants, endpoints and complete specifications constrain every request', () => {
  const data = catalog();
  const selection = selectRequest(data, 'deepclub_generate_image', imageArgs());
  assert.equal(selection.body.size, '1024x1024');
  assert.equal(selection.body.resolution, '1K');
  for (const args of [{ ...imageArgs(), specification: 'unpublished' }, { ...imageArgs(), specification: undefined },
    { ...imageArgs(), model: 'model-guessed-from-name' }, { ...imageArgs(), size: '2048x2048' }, { ...imageArgs(), n: 2 },
    { ...imageArgs(), endpoint: '/v1/other' }, { ...imageArgs(), output_path: '/etc/leak' }]) assert.throws(() => selectRequest(data, 'deepclub_generate_image', args));
  data.models[0].endpoints = ['/v1/images/edits'];
  assert.throws(() => selectRequest(data, 'deepclub_generate_image', imageArgs()), isCode('authorization'));
});

test('image POST uses scoped credential and writes through real DSH fs reservation', async t => {
  const h = await harness(t);
  assert.deepEqual([...h.tools.keys()].sort(), ['deepclub_edit_image', 'deepclub_embed', 'deepclub_generate_image', 'deepclub_generate_video', 'deepclub_get_result']);
  const value = await h.invoke('deepclub_generate_image', imageArgs());
  assert.equal(h.requests.length, 1);
  assert.equal(h.requests[0].method, 'POST');
  assert.equal(h.requests[0].path, '/v1/images/generations');
  assert.equal(h.requests[0].auth, 'Bearer ' + KEY);
  assert.equal(JSON.parse(h.requests[0].body).resolution, '1K');
  assert.equal(h.approvals.length, 1);
  assert.ok(h.approvals[0].reason.includes('可能产生服务费用'));
  assert.equal(dirname(value.files[0].path), h.root);
  assert.deepEqual(await readFile(value.files[0].path), PNG);
  assert.equal(value.meta.v, 1);
  assert.equal(value.meta.status, 'done');
  assert.ok(!JSON.stringify(value).includes(KEY));
  assert.equal((await readdir(h.root)).filter(f => f.endsWith('.tmp')).length, 0);
});

test('approval refusal, absent key, missing intent and fs denials never POST', async t => {
  const h = await harness(t);
  h.setApproval('rejected');
  await assert.rejects(h.invoke('deepclub_generate_image', imageArgs()), isCode('approval'));
  assert.equal(h.requests.length, 0);
  h.setApproval('allowed-once');
  await assert.rejects(h.invoke('deepclub_generate_image', { ...imageArgs(), user_intent: 'the model invented consent' }), isCode('permission'));
  h.setMode('read-only');
  await assert.rejects(h.invoke('deepclub_generate_image', imageArgs()), isCode('permission'));
  h.setMode('workspace-write'); h.denyWrite();
  await assert.rejects(h.invoke('deepclub_generate_image', imageArgs()), isCode('filesystem'));
  await h.setKey('', false);
  await assert.rejects(h.invoke('deepclub_generate_image', imageArgs()), isCode('credential'));
  assert.equal(h.requests.length, 0);
});

test('edits send only user-selected workspace files as multipart', async t => {
  const h = await harness(t);
  const path = join(h.root, 'reference.png');
  await writeFile(path, PNG);
  const args = { ...imageArgs(), user_intent: '编辑图片', references: [path] };
  await assert.rejects(h.invoke('deepclub_edit_image', args), isCode('reference'));
  h.user('编辑图片 ' + path + '-a-different-file');
  await assert.rejects(h.invoke('deepclub_edit_image', args), isCode('reference'));
  h.user('编辑图片 ' + path);
  await h.invoke('deepclub_edit_image', args);
  assert.equal(h.requests[0].path, '/v1/images/edits');
  assert.match(h.requests[0].contentType, /^multipart\/form-data; boundary=/);
  assert.match(h.requests[0].body, /name="image"; filename="input-1.png"/);
  assert.match(h.requests[0].body, /name="model"\r\n\r\nfixture-image/);
  assert.ok(h.approvals[0].reason.includes(path));
});

test('reference path traversal and symlink escapes fail before HTTP', async t => {
  const h = await harness(t);
  const outside = join(h.root, '..', 'outside.png');
  const link = join(h.root, 'link.png');
  await symlink('/etc/passwd', link);
  for (const path of [outside, link, '/etc/passwd', h.root, 'https://deepclub.net/input.png']) {
    h.user('编辑图片 ' + path);
    await assert.rejects(h.invoke('deepclub_edit_image', { ...imageArgs(), user_intent: '编辑图片', references: [path] }));
  }
  assert.equal(h.requests.length, 0);
});

test('catalog or reference changes during approval fail before paid request', async t => {
  const h = await harness(t);
  h.setApproval(async () => { const next = catalog(); next.tools.image_generation.enabled = false; await h.setCatalog(next, false); return 'allowed-once'; });
  await assert.rejects(h.invoke('deepclub_generate_image', imageArgs()), isCode('authorization'));
  assert.equal(h.requests.length, 0);
  await h.setCatalog(catalog());
  const path = join(h.root, 'reference.png'); await writeFile(path, PNG); h.user('编辑图片 ' + path);
  h.setApproval(async () => { await writeFile(path, Buffer.concat([PNG, Buffer.from('modified')])); return 'allowed-once'; });
  await assert.rejects(h.invoke('deepclub_edit_image', { ...imageArgs(), user_intent: '编辑图片', references: [path] }), isCode('reference'));
  assert.equal(h.requests.length, 0);
});

test('failed or lost POST is never retried and upstream text cannot leak key', async t => {
  const h = await harness(t);
  h.onRequest((_row, _req, res) => { res.statusCode = 500; res.end(JSON.stringify({ error: { message: KEY } })); return true; });
  await assert.rejects(h.invoke('deepclub_generate_image', imageArgs()), error => isCode('http')(error) && !error.message.includes(KEY));
  assert.equal(h.requests.length, 1);
  h.onRequest((_row, req) => { req.socket.destroy(); return true; });
  await assert.rejects(h.invoke('deepclub_generate_image', imageArgs()), isCode('network'));
  assert.equal(h.requests.length, 2);
});

test('embedding returns a workspace JSON artifact without dumping vectors to the model', async t => {
  const h = await harness(t);
  const value = await h.invoke('deepclub_embed', { model: 'fixture-embedding', user_intent: '计算嵌入', input: 'hello' });
  assert.equal(h.requests[0].path, '/v1/embeddings');
  assert.equal(value.files[0].mime, 'application/json');
  assert.deepEqual(JSON.parse(await readFile(value.files[0].path, 'utf8')).data, [{ index: 0, embedding: [0.5, -0.5] }]);
  assert.equal(value.meta, null);
  assert.ok(!value.text.includes('0.5'));
});

test('OpenAI video is a real session-owned DSH job and ignores completed call signal', async t => {
  const h = await harness(t);
  const call = new AbortController();
  const value = await h.invoke('deepclub_generate_video', videoArgs(), h.execution(call.signal));
  assert.ok(value.job_id.startsWith('deepclub-video-'));
  call.abort();
  await h.ctx.jobs.wait(value.job_id, 5000, h.session.id);
  assert.equal(h.ctx.jobs.get(value.job_id, h.session.id).status, 'completed');
  const result = await h.invoke('deepclub_get_result', { job_id: value.job_id });
  assert.deepEqual(await readFile(result.files[0].path), MP4);
  assert.equal(h.requests.filter(r => r.method === 'POST').length, 1);
  assert.deepEqual(h.requests.map(r => r.path), ['/v1/videos', '/v1/videos/task_openai_1', '/v1/videos/task_openai_1/content']);
  assert.match(h.requests[0].contentType, /^multipart\/form-data/);
  await assert.rejects(h.invoke('deepclub_get_result', { job_id: value.job_id }, h.execution(undefined, { ...h.agent, session: { id: 'foreign-session' } })), isCode('permission'));
  await assert.rejects(h.invoke('deepclub_get_result', { job_id: 'task_openai_1' }), isCode('permission'));
});

test('generic video uses authorized JSON protocol and downloads without bearer', async t => {
  const h = await harness(t);
  const value = await h.invoke('deepclub_generate_video', videoArgs('fixture-generic'));
  await h.ctx.jobs.wait(value.job_id, 5000, h.session.id);
  assert.equal(h.ctx.jobs.get(value.job_id, h.session.id).status, 'completed');
  assert.equal(JSON.parse(h.requests[0].body).duration, 5);
  assert.equal(h.requests[0].path, '/v1/video/generations');
  assert.equal(h.requests.at(-1).path, '/asset.mp4');
  assert.equal(h.requests.at(-1).auth, undefined);
});

test('disabled job controller prevents video POST', async t => {
  const h = await harness(t);
  h.detachController();
  await assert.rejects(h.invoke('deepclub_generate_video', videoArgs()));
  assert.equal(h.requests.length, 0);
});

test('job kill stops local polling and never sends cancellation/refund requests', async t => {
  const h = await harness(t);
  let polled;
  const firstPoll = new Promise(resolve => { polled = resolve; });
  h.onRequest((row, _req, res) => {
    if (row.path !== '/v1/videos/task_openai_1') return false;
    res.end(JSON.stringify({ id: 'task_openai_1', status: 'in_progress' })); polled(); return true;
  });
  const value = await h.invoke('deepclub_generate_video', videoArgs());
  await firstPoll;
  await h.ctx.jobs.kill(value.job_id, h.session.id);
  await h.ctx.jobs.wait(value.job_id, 5000, h.session.id);
  const result = await h.invoke('deepclub_get_result', { job_id: value.job_id });
  assert.match(result.text, /未确认上游取消或退款/);
  assert.equal(h.ctx.jobs.get(value.job_id, h.session.id).status, 'killed');
  assert.equal(h.requests.filter(r => r.method !== 'GET' && r.method !== 'POST').length, 0);
  assert.equal(h.requests.filter(r => r.method === 'POST').length, 1);
});

test('config refresh replaces tools and immediately invalidates captured old executors', async t => {
  const h = await harness(t);
  const old = h.tools.get('deepclub_generate_image');
  const next = catalog(); next.models[0].id = 'new-image'; next.tools.image_generation.model_ids = ['new-image']; next.tools.image_editing.enabled = false;
  await h.setCatalog(next);
  assert.ok(!h.tools.has('deepclub_edit_image'));
  await assert.rejects(old.execute(imageArgs(), h.execution()), isCode('authorization'));
  await h.invoke('deepclub_generate_image', { ...imageArgs(), model: 'new-image' });
  assert.equal(JSON.parse(h.requests[0].body).model, 'new-image');
  const currentTool = h.tools.get('deepclub_generate_image');
  await h.setCatalog({ models: [], tools: {} });
  assert.equal(h.tools.size, 0);
  await assert.rejects(currentTool.execute({ ...imageArgs(), model: 'new-image' }, h.execution()));
  await h.setCatalog(catalog()); await h.setKey('');
  assert.equal(h.tools.size, 0);
});

test('logout retires video polling and old result handles; new login starts clean', async t => {
  const h = await harness(t);
  let polled; const firstPoll = new Promise(resolve => { polled = resolve; });
  h.onRequest((row, _req, res) => {
    if (row.path !== '/v1/videos/task_openai_1') return false;
    res.end(JSON.stringify({ id: 'task_openai_1', status: 'queued' })); polled(); return true;
  });
  const value = await h.invoke('deepclub_generate_video', videoArgs());
  const resultTool = h.tools.get('deepclub_get_result');
  await firstPoll;
  await h.setCatalog({ models: [], tools: {} }); await h.setKey('');
  await h.ctx.jobs.wait(value.job_id, 5000, h.session.id);
  const count = h.requests.length;
  await assert.rejects(resultTool.execute({ job_id: value.job_id }, h.execution()), isCode('permission'));
  await h.setKey('second-synthetic-key'); await h.setCatalog(catalog());
  await assert.rejects(h.invoke('deepclub_get_result', { job_id: value.job_id }), isCode('permission'));
  assert.equal(h.requests.length, count);
});

test('credential rotation while approval is pending refuses the paid POST', async t => {
  const h = await harness(t);
  h.setApproval(async () => { await h.setKey('rotated-during-approval', false); return 'allowed-once'; });
  await assert.rejects(h.invoke('deepclub_generate_image', imageArgs()), isCode('credential'));
  assert.equal(h.requests.length, 0);
});

test('logout before response publication prevents output even without an event', async t => {
  const h = await harness(t);
  h.onRequest(async (_row, _req, res) => {
    await h.setKey('', false);
    res.end(JSON.stringify({ data: [{ b64_json: PNG.toString('base64') }] }));
    return true;
  });
  await assert.rejects(h.invoke('deepclub_generate_image', imageArgs()), isCode('credential'));
  assert.equal(h.requests.length, 1);
  assert.deepEqual(await readdir(h.root), []);
});

test('download URLs receive no bearer and redirects never cause another POST', async t => {
  const h = await harness(t);
  h.onRequest((row, _req, res) => {
    if (row.path === '/v1/images/generations') res.end(JSON.stringify({ data: [{ url: h.base + '/image.png' }] }));
    else if (row.path === '/image.png') res.end(PNG);
    else return false;
    return true;
  });
  await h.invoke('deepclub_generate_image', imageArgs());
  assert.equal(h.requests.at(-1).auth, undefined);
  h.onRequest((_row, _req, res) => { res.statusCode = 307; res.setHeader('Location', h.base + '/paid-again'); res.end(); return true; });
  await assert.rejects(h.invoke('deepclub_generate_image', imageArgs()), isCode('http'));
  assert.equal(h.requests.filter(r => r.method === 'POST').length, 2);
  assert.ok(!h.requests.some(r => r.path === '/paid-again'));
});

test('a substituted binary reservation never overwrites its symlink target', async t => {
  const h = await harness(t);
  const victim = join(h.root, 'keep.txt'); await writeFile(victim, 'unchanged');
  const original = h.ctx.fs.writeText.bind(h.ctx.fs);
  h.ctx.fs.writeText = async (...args) => {
    const value = await original(...args);
    const path = h.ctx.fs.processPath(args[0]);
    if (path.endsWith('.png')) {
      assert.equal(dirname(path), h.root);
      assert.match(path, /deepclub-[a-f0-9-]+\.png$/);
      await rm(path); await symlink(victim, path);
    }
    return value;
  };
  await assert.rejects(h.invoke('deepclub_generate_image', imageArgs()), isCode('filesystem'));
  assert.equal(await readFile(victim, 'utf8'), 'unchanged');
  assert.equal(h.requests.length, 1);
});

test('result access revalidates catalog and key even without an update event', async t => {
  const h = await harness(t);
  const value = await h.invoke('deepclub_generate_video', videoArgs());
  await h.ctx.jobs.wait(value.job_id, 5000, h.session.id);
  await h.setKey('rotated-without-event', false);
  await assert.rejects(h.invoke('deepclub_get_result', { job_id: value.job_id }), isCode('credential'));
  await h.setKey(KEY, false); await h.setCatalog({ models: [], tools: {} }, false);
  await assert.rejects(h.invoke('deepclub_get_result', { job_id: value.job_id }), isCode('authorization'));
});
