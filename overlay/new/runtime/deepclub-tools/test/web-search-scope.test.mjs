import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

// For artifact verification, point this at an isolated prefix containing the
// pinned APK's @deepseek-ai packages. Never rewrite an installed runtime.
const artifactPrefix = process.env.DEEPCLUB_TEST_DSH_PREFIX;
const require = createRequire(artifactPrefix ? join(artifactPrefix, 'package.json') : new URL('../package.json', import.meta.url));
const load = name => import(pathToFileURL(require.resolve(name)).href);
const [{ Context }, { default: Tools }, { default: SystemPrompt }, WebTools, { createScope }, { loadOverlayPatches }] = await Promise.all([
  load('@deepseek-ai/cordis'), load('@deepseek-ai/dsh-tools'), load('@deepseek-ai/dsh-system-prompt'),
  load('@deepseek-ai/dsh-tool-web'), load('@deepseek-ai/dsh-scope'), load('@deepseek-ai/dsh-app-boot'),
]);
const bundle = dirname(require.resolve('@deepseek-ai/dsh-web-app/package.json'));
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

// Exact inputs from dsh-Go 288234a's checksum-pinned Android runtime APK.
// The build recipe can use these original hashes + the unique block below;
// only one configuration line changes. These are not model inventory pins.
const pins = {
  standard: ['3006cc3780cddaa7fb0089e5854e6bbef4409cf1d425930fd835226b95660afd', 'd7ac1fea64369fb9340013833bfb8960ebcad25c4747c9598362c918dd58f005'],
  ptc: ['ce02148b1fd575cc93071744180468cd305bdcd50dbfdd3b9b0605c5281d283d', 'd8b1058efc2d376f5c0b769cbbeb0702d79476cbacae5b3c3c6cad670d3af150'],
  cordis: ['0e8f611644b3c36249808c4d7eb7a40d78006d04da6b55eef1a42797a5a34355', 'ddf3f4eced54951d06443388646b1ca4791b1bcde5e9a455a1793d8c1e1eee3c'],
  minimal: ['a2a9ba1c9c392a45466708f18bc0aefbf300577f9b544dc06049f73a8a5b3267'],
};
const oldBlock = "          - id: tool-web\n            name: '@deepseek-ai/dsh-tool-web'\n            config:\n              fetch: true\n              searchTimeoutMs: 60000\n";
const newBlock = oldBlock.replace('              fetch: true\n', '              fetch: true\n              search: false\n');

async function harness(t) {
  const ctx = new Context(), fibers = [], scopes = [], requests = [];
  fibers.push(await ctx.plugin(SystemPrompt));
  fibers.push(await ctx.plugin(Tools));
  const disposeWeb = ctx.provide('web', {
    // Keep both ready: provider absence must not hide a registration regression.
    searchReady: () => true, fetchReady: () => true,
    search() { throw new Error('No search request is permitted in this test'); },
    async fetch({ url }) {
      requests.push(url);
      return { url, statusCode: 200, body: { kind: 'text', content: 'scope fixture' }, truncated: false };
    },
  });
  t.after(async () => {
    for (const scope of scopes.reverse()) await scope.dispose();
    for (const fiber of fibers.reverse()) await fiber.dispose();
    disposeWeb();
  });
  // Mirrors the insufficient root override: it cannot suppress another scope's
  // own default-enabled search registration.
  fibers.push(await ctx.plugin(WebTools, { search: false, fetch: true }));
  async function agentFor(config) {
    const presetKey = {}, preset = createScope(ctx, presetKey);
    scopes.push(preset);
    if (config) await preset.ctx.plugin(WebTools, config);
    const agent = { session: { id: 'scope-fixture' } };
    const child = createScope(ctx, agent, { parent: presetKey });
    scopes.push(child); agent.ctx = child.ctx;
    const signal = new AbortController().signal;
    const toolSet = await ctx.tools.resolve({ agent, modelSelection: { provider: 'fixture', model: 'fixture' }, signal });
    t.after(() => toolSet.dispose());
    return { agent, signal, toolSet, names: ctx.tools.schemas(agent, toolSet).map(tool => tool.name).sort() };
  }
  return { ctx, agentFor, requests };
}

for (const preset of ['standard', 'ptc', 'cordis']) {
  test(`${preset}: preset search:false removes scoped web_search while web_fetch executes`, async t => {
    const path = join(bundle, 'presets', `${preset}.patch.yml`);
    const source = await readFile(path, 'utf8');
    assert.equal(source.split(oldBlock).length - 1, 1, 'patch must match one complete tool-web row');
    if (artifactPrefix) {
      assert.equal(sha256(source), pins[preset][0], 'unexpected pinned Android preset');
      assert.equal(sha256(source.replace(oldBlock, newBlock)), pins[preset][1]);
    }
    const rows = loadOverlayPatches('dsh', path);
    const declaration = rows.flatMap(row => row.insert ?? []).find(row => row.config?.id === preset);
    const selected = declaration.config.plugins.filter(row => row.id === 'tool-web');
    assert.equal(selected.length, 1);
    assert.deepEqual(selected[0].config, { fetch: true, searchTimeoutMs: 60000 });
    const h = await harness(t);
    const before = await h.agentFor(selected[0].config);
    assert.deepEqual(before.names, ['web_fetch', 'web_search'], 'root search:false does not remove a preset-owned tool');
    const after = await h.agentFor({ ...selected[0].config, search: false });
    assert.deepEqual(after.names, ['web_fetch']);
    assert.equal(h.ctx.tools.get('web_search', after.agent, after.toolSet), undefined);
    // A sibling with the original config remains unchanged: this is a scope
    // result, not deletion of a global web service or a tool-registry stub.
    assert.deepEqual(h.ctx.tools.schemas(before.agent, before.toolSet).map(tool => tool.name).sort(), before.names);
    const fetch = h.ctx.tools.get('web_fetch', after.agent, after.toolSet);
    const result = await fetch.execute({ url: 'https://example.test/fixture' }, { agent: after.agent, signal: after.signal, callId: 'fetch-fixture' });
    assert.equal(result.body.content, 'scope fixture');
    assert.deepEqual(h.requests, ['https://example.test/fixture']);
  });
}

test('minimal has no tool-web row and needs no preset mutation', async t => {
  const path = join(bundle, 'presets', 'minimal.patch.yml');
  const source = await readFile(path, 'utf8');
  if (artifactPrefix) assert.equal(sha256(source), pins.minimal[0]);
  assert.equal(source.includes(oldBlock), false);
  const declaration = loadOverlayPatches('dsh', path).flatMap(row => row.insert ?? []).find(row => row.config?.id === 'minimal');
  assert.equal(declaration.config.plugins.some(row => row.id === 'tool-web'), false);
  const h = await harness(t);
  const minimal = await h.agentFor();
  assert.deepEqual(minimal.names, ['web_fetch'], 'minimal adds no search and preserves any host fetch capability');
});
