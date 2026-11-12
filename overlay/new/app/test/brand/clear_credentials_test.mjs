import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtemp, readFile, writeFile, stat, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { clearDeepClubCredentials } from '../../assets/engine/deepclub/clear-credentials.mjs';

const runtimePackage = process.env.DSH_CREDENTIALS_PACKAGE;
if (!runtimePackage) throw new Error('Set DSH_CREDENTIALS_PACKAGE to the bundled dsh-credentials-local/package.json');
const yaml = createRequire(runtimePackage)('yaml');

async function fixture(body, run) {
  const dir = await mkdtemp(join(tmpdir(), 'deepclub-credentials-test-'));
  const path = join(dir, '.credentials.yaml');
  try {
    if (body !== null) await writeFile(path, body, { mode: 0o600 });
    await run(path, dir);
  } finally {
    // This directory was allocated by this test and contains only its fixtures.
    assert.ok(dir.startsWith(join(tmpdir(), 'deepclub-credentials-test-')));
    await rm(dir, { recursive: true, force: true });
  }
}

test('removes only our reference and preserves other keys, records and comments', async () => {
  const body = '# keep this comment\nversion: 1\nrefs:\n  DEEPCLUB_API_KEY: sample-owned-secret\n  OTHER_KEY: |\n    line one\n    line two\nrecords:\n  other: {tag: opaque, data: kept}\nforeign: [1, 2]\n';
  await fixture(body, async path => {
    await clearDeepClubCredentials(path, yaml);
    const text = await readFile(path, 'utf8');
    const data = yaml.parse(text);
    assert.equal(data.refs.DEEPCLUB_API_KEY, undefined);
    assert.equal(data.refs.OTHER_KEY, 'line one\nline two\n');
    assert.deepEqual(data.records, { other: { tag: 'opaque', data: 'kept' } });
    assert.deepEqual(data.foreign, [1, 2]);
    assert.match(text, /# keep this comment/);
    assert.equal((await stat(path)).mode & 0o777, 0o600);
  });
});

test('does not rewrite a document without our key', async () => {
  const body = 'version: 1\nrefs: { OTHER_KEY: other }\n';
  await fixture(body, async path => {
    await clearDeepClubCredentials(path, yaml);
    assert.equal(await readFile(path, 'utf8'), body);
  });
});

test('rejects malformed, duplicate-key and unsupported documents without changing them', async () => {
  for (const body of ['version: [\n', 'version: 1\nversion: 1\n', 'version: 2\nrefs: {}\n', 'version: 1\nrefs: [invalid]\n']) {
    await fixture(body, async path => {
      await assert.rejects(clearDeepClubCredentials(path, yaml));
      assert.equal(await readFile(path, 'utf8'), body);
    });
  }
});

test('a missing credential document stays absent', async () => {
  await fixture(null, async path => {
    await clearDeepClubCredentials(path, yaml);
    await assert.rejects(stat(path), { code: 'ENOENT' });
  });
});

test('does not follow a credential-file symlink', async () => {
  await fixture(null, async (path, dir) => {
    const target = join(dir, 'other.yaml');
    await writeFile(target, 'version: 1\nrefs: { DEEPCLUB_API_KEY: sample }\n');
    await symlink(target, path);
    await assert.rejects(clearDeepClubCredentials(path, yaml), /credentials_path_invalid/);
    assert.match(await readFile(target, 'utf8'), /DEEPCLUB_API_KEY/);
  });
});
