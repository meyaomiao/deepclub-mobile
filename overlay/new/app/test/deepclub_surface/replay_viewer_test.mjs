import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

await import('../../../site/share/viewer.js');
const viewer = globalThis.DshgoViewer;
const fixture = JSON.parse(readFileSync(new URL('../replay/fixtures/timeline.json', import.meta.url), 'utf8'));

test('legacy local conversation still opens and replays with embedded pictures', async () => {
  const opened = await viewer.openFile(fixture.file);
  assert.equal(opened.conversation.title, '修复登录重复提交');
  assert.equal(opened.conversation.entries.length, 14);
  assert.equal(Object.keys(opened.assets).length, 1);
  assert.ok(Object.values(opened.assets)[0].startsWith('data:image/png;base64,'));
  const timeline = viewer.timeline(opened.conversation.entries);
  assert.equal(timeline.duration, fixture.timeline.duration);
});

test('hosted viewer fails before invoking any fetch implementation', async () => {
  let requests = 0;
  const fetch = async () => {
    requests++;
    throw new Error('network must not be used');
  };
  await assert.rejects(viewer.openHosted('a1B2c3D4e5', 'A'.repeat(43), fetch), /unavailable/);
  assert.equal(requests, 0);
});

test('local format integrity remains enforced', async () => {
  const envelope = JSON.parse(fixture.file);
  const code = envelope.code;
  envelope.code = code.slice(0, 10) + (code[10] === 'A' ? 'B' : 'A') + code.slice(11);
  await assert.rejects(viewer.openFile(JSON.stringify(envelope)), /format/);
});
