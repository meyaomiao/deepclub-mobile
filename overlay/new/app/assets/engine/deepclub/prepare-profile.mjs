// Register the mobile tools in the profile's own writable patch, before dsh web
// loads it. Catalog configuration remains owned by the authenticated Dart sync.
import { createRequire } from 'node:module';
import { lstat, readFile, mkdir, open, rename, unlink } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';

export const toolsId = 'deepclub-tools';
export const toolsSource = 'file:///opt/dsh-go/deepclub-tools/src/index.js';

export class ProfilePreparationError extends Error {
  constructor(code) { super(code); this.code = code; }
}

function fail(code) { throw new ProfilePreparationError(code); }
function mapping(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }

/** Ordinary id-targeted overrides are not registrations; retain them in order. */
function registrations(rows) {
  let count = 0;
  const visiting = new Set();
  function entries(list) {
    if (!Array.isArray(list) || visiting.has(list)) fail('deepclub_profile_invalid');
    visiting.add(list);
    for (const entry of list) {
      if (!mapping(entry)) fail('deepclub_profile_invalid');
      if (entry.id === toolsId) {
        count++;
        if (entry.name !== toolsSource) fail('deepclub_profile_source_conflict');
      }
      // Loader ids include nested group entries, but arbitrary plugin config
      // objects may have unrelated fields named id and must not be traversed.
      if (entry.group === true && Array.isArray(entry.config)) entries(entry.config);
    }
    visiting.delete(list);
  }
  for (const row of rows) {
    if (!mapping(row)) fail('deepclub_profile_invalid');
    if (Object.hasOwn(row, 'insert')) entries(row.insert);
    else if (row.id === toolsId && Object.hasOwn(row, 'name') && row.name !== toolsSource) {
      fail('deepclub_profile_source_conflict');
    }
  }
  if (count > 1) fail('deepclub_profile_duplicate');
  return count;
}

export async function prepareProfile(filename, yaml, { replace = rename } = {}) {
  let before = '';
  try {
    const info = await lstat(filename);
    if (!info.isFile() || info.isSymbolicLink()) fail('deepclub_profile_path_invalid');
    before = await readFile(filename, 'utf8');
  } catch (error) {
    if (error instanceof ProfilePreparationError) throw error;
    if (error.code !== 'ENOENT') fail('deepclub_profile_read_failed');
  }
  const document = yaml.parseDocument(before, {
    uniqueKeys: true,
    prettyErrors: false,
    customTags: [{ tag: 'tag:yaml.org,2002:js', resolve: value => value }],
  });
  if (document.errors.length) fail('deepclub_profile_invalid');
  if (document.contents === null) document.contents = document.createNode([]);
  if (!yaml.isSeq(document.contents)) fail('deepclub_profile_invalid');
  let rows;
  try { rows = document.toJS(); }
  catch { fail('deepclub_profile_invalid'); }
  // Idempotent, byte-for-byte: preserve existing config, disabled, comments and
  // formatting without granting this helper ownership of any of those fields.
  if (registrations(rows) === 1) return { changed: false };
  document.contents.items.unshift(document.createNode({ insert: [{ id: toolsId, name: toolsSource }] }));
  document.contents.flow = false;
  const temporary = join(dirname(filename), `.deepclub-profile-${randomUUID()}.tmp`);
  let file;
  try {
    await mkdir(dirname(filename), { recursive: true, mode: 0o700 });
    file = await open(temporary, 'wx', 0o600);
    await file.writeFile(document.toString(), 'utf8');
    await file.sync();
    await file.close();
    file = null;
    await replace(temporary, filename);
  } catch {
    fail('deepclub_profile_write_failed');
  } finally {
    await file?.close();
    await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error; });
  }
  return { changed: true };
}

const failureExit = {
  deepclub_profile_invalid: 2,
  deepclub_profile_source_conflict: 3,
  deepclub_profile_duplicate: 4,
  deepclub_profile_write_failed: 5,
  deepclub_profile_path_invalid: 6,
  deepclub_profile_read_failed: 7,
};

async function main() {
  const require = createRequire('/opt/dsh/node_modules/@deepseek-ai/dsh-credentials-local/package.json');
  await prepareProfile('/root/.dsh/profiles/web/cordis.patch.yml', require('yaml'));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().then(() => { process.stdout.write('prepared\n'); }, error => {
    // Parser and filesystem messages can contain user configuration; only fixed
    // codes cross the process boundary and appear in the runtime startup error.
    process.stderr.write(`${failureExit[error.code] ? error.code : 'deepclub_profile_prepare_failed'}\n`);
    process.exitCode = failureExit[error.code] ?? 1;
  });
}
