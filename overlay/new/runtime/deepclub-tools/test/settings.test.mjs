import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, realpath, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { Context } from '@deepseek-ai/cordis';
import Loader from '@deepseek-ai/cordis-plugin-loader';
import ConfigEditor from '@deepseek-ai/dsh-config-editor';
import Settings from '@deepseek-ai/dsh-settings';
import { initProfile, loadOverlayPatches, mountRootInclude } from '@deepseek-ai/dsh-app-boot';
import * as Plugin from '../src/index.js';

// Real profile patch / ConfigEditor / Settings / Loader, with non-I/O service
// stand-ins. CLI mode loads the same patch file into profileContext.overlays
// that the launcher populates from --patch; no tool or external request runs.
async function settingsFixture(t, { cliInsert = false } = {}) {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'deepclub-tools-settings-')));
  const ctx = new Context();
  const fibers = [], disposers = [], tools = new Map();
  const pluginPath = fileURLToPath(new URL('../src/index.js', import.meta.url));
  const anchor = createRequire(import.meta.url).resolve('@deepseek-ai/dsh/package.json');
  initProfile(root, []);
  const basePath = join(root, 'cordis.yml'), patchPath = join(root, 'cordis.patch.yml');
  await writeFile(basePath, '[]\n');
  const disabledIds = ['llm-deepseek-account', 'web-search-deepseek', 'web-deepseek-api', 'session-telemetry-otel', 'dsh-media'];
  const insertion = { insert: [{ id: 'deepclub-tools', name: pathToFileURL(pluginPath).href }] };
  const patches = [...(cliInsert ? [] : [insertion]), ...disabledIds.map(id => ({ id, disabled: true }))];
  await writeFile(patchPath, JSON.stringify(patches));
  const overlayPath = join(root, 'cli.patch.yml');
  await writeFile(overlayPath, JSON.stringify(cliInsert ? [insertion] : []));
  const overlays = loadOverlayPatches('dsh', overlayPath);
  ctx.baseUrl = pathToFileURL(root).href + '/';
  t.after(async () => {
    for (const fiber of fibers.reverse()) await fiber.dispose();
    for (const dispose of disposers.reverse()) dispose();
    assert.equal(await realpath(root), root);
    assert.ok(root.startsWith(await realpath(tmpdir()) + '/deepclub-tools-settings-'));
    await rm(root, { recursive: true });
  });
  disposers.push(ctx.provide('profileContext', { home: join(root, 'home'), dir: root, name: 'test', patchPath, installAnchor: anchor, overlays }));
  for (const [name, value] of Object.entries({
    credentials: { describe: async () => ({ configured: true }) },
    tools: { register(tool) { assert.ok(!tools.has(tool.name)); tools.set(tool.name, tool); return () => tools.delete(tool.name); } },
    fs: {}, workingDirectory: {}, sandboxPolicy: {}, approval: {},
    jobs: { events: { subscribe: () => () => {} } },
    systemPrompt: { section: () => () => {} },
  })) disposers.push(ctx.provide(name, value));
  fibers.push(await ctx.plugin(Loader));
  ctx.loader.internal = { version: 'v2', async import(specifier) {
    assert.ok([pluginPath, pathToFileURL(pluginPath).href].includes(specifier));
    return Plugin;
  } };
  await mountRootInclude(ctx, basePath, [...patches, ...overlays]);
  await ctx.loader.await();
  assert.ok([...ctx.loader.entries()].every(entry => !disabledIds.includes(entry.options.id)), 'absent disabled rows must not create plugins');
  fibers.push(await ctx.plugin(ConfigEditor));
  fibers.push(await ctx.plugin(Settings));
  const initial = ctx.settings.describe().find(row => row.ns === 'deepclub-tools');
  assert.ok(initial);
  assert.deepEqual(initial.value, { catalog: {} });
  assert.equal(tools.size, 0);
  const fixture = {
    revision: 'smoke-1', base_url: 'https://deepclub.net', api_key_env: 'DEEPCLUB_API_KEY',
    tools: { embedding: { enabled: true, model_ids: ['smoke-embedding'] } },
    models: [{ id: 'smoke-embedding', category: 'embedding', endpoints: ['/v1/embeddings'] }],
  };
  const entry = ctx.configEditor.entries().find(row => row.options.id === 'deepclub-tools');
  return { ctx, tools, patchPath, overlayPath, initial, fixture, entry };
}

test('profile-owned insertion lets settings/mutate replace catalog through real Loader', async t => {
  const { ctx, tools, patchPath, initial, fixture, entry } = await settingsFixture(t);
  const uid = entry.fiber.uid;
  await ctx.settings.mutate('deepclub-tools', [{ op: 'set', path: ['catalog'], value: fixture }], initial.revision);
  await ctx.loader.await();
  assert.equal(entry.fiber.uid, uid, 'volatile catalog must update without replacing the plugin');
  assert.deepEqual(entry.fiber.effectiveConfig.catalog.get(), fixture);
  assert.deepEqual([...tools.keys()], ['deepclub_embed']);
  assert.match(await readFile(patchPath, 'utf8'), /smoke-embedding/);
  await ctx.settings.mutate('deepclub-tools', [{ op: 'set', path: ['catalog'], value: { models: [], tools: {} } }]);
  await ctx.loader.await();
  assert.equal(tools.size, 0);
  assert.deepEqual(ctx.settings.describe().find(row => row.ns === 'deepclub-tools').value.catalog, { models: [], tools: {} });
});

test('CLI --patch insertion rejects settings writes without changing disk or live catalog', async t => {
  const { ctx, tools, patchPath, overlayPath, initial, fixture, entry } = await settingsFixture(t, { cliInsert: true });
  const before = await readFile(patchPath, 'utf8');
  const overlayBefore = await readFile(overlayPath, 'utf8');
  const uid = entry.fiber.uid;
  await assert.rejects(
    ctx.settings.mutate('deepclub-tools', [{ op: 'set', path: ['catalog'], value: fixture }], initial.revision),
    { message: 'Configuration for "deepclub-tools" is overridden by a home patch or command-line overlay' },
  );
  await ctx.loader.await();
  assert.equal(await readFile(patchPath, 'utf8'), before);
  assert.equal(await readFile(overlayPath, 'utf8'), overlayBefore);
  assert.equal(entry.fiber.uid, uid);
  assert.deepEqual(entry.fiber.effectiveConfig.catalog.get(), {});
  const after = ctx.settings.describe().find(row => row.ns === 'deepclub-tools');
  assert.equal(after.revision, initial.revision);
  assert.deepEqual(after.value.catalog, {});
  assert.equal(tools.size, 0);
});
