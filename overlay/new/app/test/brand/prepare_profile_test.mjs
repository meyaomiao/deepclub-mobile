import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtemp, mkdir, readFile, writeFile, stat, symlink, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { prepareProfile, toolsId, toolsSource } from '../../assets/engine/deepclub/prepare-profile.mjs';

const runtimePackage = process.env.DSH_CREDENTIALS_PACKAGE;
if (!runtimePackage) throw new Error('Set DSH_CREDENTIALS_PACKAGE to the bundled dsh-credentials-local/package.json');
const yaml = createRequire(runtimePackage)('yaml');
const registration = { insert: [{ id: toolsId, name: toolsSource }] };

async function fixture(body, run) {
  const root = await mkdtemp(join(tmpdir(), 'deepclub-profile-test-'));
  const filename = join(root, 'profiles/web/cordis.patch.yml');
  try {
    if (body !== null) {
      await mkdir(dirname(filename), { recursive: true });
      await writeFile(filename, body, { mode: 0o640 });
    }
    await run(filename, root);
  } finally {
    assert.ok(root.startsWith(join(tmpdir(), 'deepclub-profile-test-')));
    await rm(root, { recursive: true, force: true });
  }
}

async function unchangedOnError(body, code) {
  await fixture(body, async filename => {
    await assert.rejects(prepareProfile(filename, yaml), { code });
    assert.equal(await readFile(filename, 'utf8'), body);
    assert.deepEqual(await readdir(dirname(filename)), ['cordis.patch.yml']);
  });
}

test('creates only a profile-owned registration with mode 0600 and no catalog', async () => {
  await fixture(null, async filename => {
    assert.deepEqual(await prepareProfile(filename, yaml), { changed: true });
    assert.deepEqual(yaml.parse(await readFile(filename, 'utf8')), [registration]);
    assert.equal((await stat(filename)).mode & 0o777, 0o600);
    assert.deepEqual(await readdir(dirname(filename)), ['cordis.patch.yml']);
  });
});

test('repeated preparation keeps the first result byte-for-byte without replacing its inode', async () => {
  for (const body of [null, '', '# my profile\n[]\n', '# empty profile\n']) {
    await fixture(body, async filename => {
      await prepareProfile(filename, yaml);
      const before = await readFile(filename, 'utf8');
      const original = await stat(filename);
      assert.deepEqual(await prepareProfile(filename, yaml), { changed: false });
      assert.equal(await readFile(filename, 'utf8'), before);
      assert.equal((await stat(filename)).ino, original.ino);
    });
  }
});

test('same-source registration preserves disabled, config, later overrides and formatting', async () => {
  const body = `# keep this comment\n- insert:\n    - id: ${toolsId}\n      name: '${toolsSource}'\n      disabled: true\n      config: {catalog: {revision: retained, models: []}} # retain config\n- id: ${toolsId}\n  config:\n    catalog: {revision: newer, tools: {image: true}}\n- id: other\n  disabled: false\n`;
  await fixture(body, async filename => {
    assert.deepEqual(await prepareProfile(filename, yaml), { changed: false });
    assert.equal(await readFile(filename, 'utf8'), body);
    assert.equal((await stat(filename)).mode & 0o777, 0o640, 'unchanged file is not rewritten just to chmod');
  });
});

test('prepends registration before prior partial pi/default/catalog overrides and retains all user rows', async () => {
  const body = `# pi configuration was applied before the failed catalog mutation\n- id: llm-pi-ai\n  config:\n    providers:\n      deepclub-test: {baseUrl: 'https://deepclub.net/v1', apiKey: {ref: DEEPCLUB_API_KEY}}\n- id: agent-default-model\n  config: {provider: deepclub-test, model: sample-model, reasoningEffort: high}\n# Older catalog override must follow the newly registered plugin\n- id: ${toolsId}\n  name: '${toolsSource}'\n  disabled: true\n  config: {catalog: {revision: partial, models: [], tools: {}}}\n- id: unrelated\n  config:\n    note: |\n      keep this literal text\n      and its second line\n`;
  await fixture(body, async filename => {
    const prior = yaml.parse(body);
    await prepareProfile(filename, yaml);
    const after = await readFile(filename, 'utf8');
    const rows = yaml.parse(after);
    assert.deepEqual(rows[0], registration);
    assert.deepEqual(rows.slice(1), prior);
    assert.ok(after.includes('# pi configuration was applied'));
    assert.ok(after.includes('# Older catalog override'));
    assert.equal(rows[0].insert[0].config, undefined);
    assert.deepEqual(await prepareProfile(filename, yaml), { changed: false });
  });
});

test('retains JS-tagged user configuration as a tagged scalar without evaluating it', async () => {
  const body = "- id: other\n  config:\n    expression: !!js process.env.USER_SETTING\n";
  await fixture(body, async filename => {
    await prepareProfile(filename, yaml);
    const document = yaml.parseDocument(await readFile(filename, 'utf8'), {
      customTags: [{ tag: 'tag:yaml.org,2002:js', resolve: value => value }],
    });
    const expression = document.getIn([1, 'config', 'expression'], true);
    assert.equal(expression.tag, 'tag:yaml.org,2002:js');
    assert.equal(expression.value, 'process.env.USER_SETTING');
  });
});

test('duplicate registrations, including nested group definitions, fail without rewriting', async () => {
  const entry = registration.insert[0];
  for (const rows of [
    [{ insert: [entry, entry] }],
    [registration, registration],
    [registration, { insert: [{ id: 'group', name: 'cordis:group', group: true, config: [entry] }] }],
  ]) {
    await unchangedOnError(yaml.stringify(rows), 'deepclub_profile_duplicate');
  }
});

test('a registration or named override with a different source fails closed', async () => {
  for (const rows of [
    [{ insert: [{ id: toolsId, name: 'file:///different/tools.js' }] }],
    [{ insert: [{ id: toolsId }] }],
    [registration, { id: toolsId, name: 'file:///different/tools.js', config: {} }],
  ]) {
    await unchangedOnError(yaml.stringify(rows), 'deepclub_profile_source_conflict');
  }
});

test('invalid YAML, duplicate mapping keys and invalid patch shapes leave existing files intact', async () => {
  for (const body of ['[broken\n', 'patch: []\n', '- id: first\n  id: second\n', '- insert: nope\n', '- null\n']) {
    await unchangedOnError(body, 'deepclub_profile_invalid');
  }
});

test('a failed atomic replacement preserves the old profile and removes the temporary file', async () => {
  const body = '- id: agent-default-model\n  config: {model: existing}\n';
  await fixture(body, async filename => {
    let staged;
    await assert.rejects(prepareProfile(filename, yaml, {
      replace: async (temporary, target) => {
        staged = {
          target,
          mode: (await stat(temporary)).mode & 0o777,
          rows: yaml.parse(await readFile(temporary, 'utf8')),
          original: await readFile(target, 'utf8'),
        };
        throw Object.assign(new Error('simulated disk failure'), { code: 'EIO' });
      },
    }), { code: 'deepclub_profile_write_failed' });
    assert.equal(staged.target, filename);
    assert.equal(staged.mode, 0o600);
    assert.deepEqual(staged.rows[0], registration);
    assert.equal(staged.original, body, 'the original stays visible until commit');
    assert.equal(await readFile(filename, 'utf8'), body);
    assert.deepEqual(await readdir(dirname(filename)), ['cordis.patch.yml']);
  });
});

test('does not follow a profile patch symlink', async () => {
  await fixture(null, async (filename, root) => {
    const target = join(root, 'other.yml');
    await mkdir(dirname(filename), { recursive: true });
    await writeFile(target, '[]\n');
    await symlink(target, filename);
    await assert.rejects(prepareProfile(filename, yaml), { code: 'deepclub_profile_path_invalid' });
    assert.equal(await readFile(target, 'utf8'), '[]\n');
  });
});
