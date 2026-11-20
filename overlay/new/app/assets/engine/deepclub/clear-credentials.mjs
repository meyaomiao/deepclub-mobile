// DeepClub offline sign-out. Uses the exact YAML document format owned by
// @deepseek-ai/dsh-credentials-local; never prints a document or parser error.
import { createRequire } from 'node:module';
import { lstat, readFile, open, rename, unlink } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';

export async function clearDeepClubCredentials(filename, yaml) {
  let info;
  try { info = await lstat(filename); }
  catch (error) { if (error.code === 'ENOENT') return; throw new Error('credentials_read_failed'); }
  if (!info.isFile() || info.isSymbolicLink()) throw new Error('credentials_path_invalid');
  const document = yaml.parseDocument(await readFile(filename, 'utf8'), { uniqueKeys: true, prettyErrors: false });
  if (document.errors.length || (document.contents !== null && !yaml.isMap(document.contents))) {
    throw new Error('credentials_document_invalid');
  }
  if (document.contents === null || document.contents.items.length === 0) return;
  if (document.get('version') !== 1) throw new Error('credentials_version_unsupported');
  const refs = document.get('refs', true);
  if (refs !== undefined && !yaml.isMap(refs)) throw new Error('credentials_refs_invalid');
  if (!refs?.has('DEEPCLUB_API_KEY')) return;
  document.deleteIn(['refs', 'DEEPCLUB_API_KEY']);
  const temporary = join(dirname(filename), `.deepclub-credentials-${randomUUID()}.tmp`);
  let file;
  try {
    file = await open(temporary, 'wx', 0o600);
    await file.writeFile(document.toString(), 'utf8');
    await file.sync();
    await file.close();
    file = null;
    await rename(temporary, filename);
  } finally {
    await file?.close();
    await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error; });
  }
}

async function main() {
  const require = createRequire('/opt/dsh/node_modules/@deepseek-ai/dsh-credentials-local/package.json');
  const yaml = require('yaml');
  // The main app always uses this DSH_HOME. Rescue mode has its own separate
  // credentials document and is cleaned as well if present.
  await clearDeepClubCredentials('/root/.dsh/.credentials.yaml', yaml);
  await clearDeepClubCredentials('/var/lib/dsh-app/safe-mode/home/.credentials.yaml', yaml);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().then(() => { process.stdout.write('cleared\n'); }, () => {
    process.stderr.write('deepclub_credentials_cleanup_failed\n');
    process.exitCode = 1;
  });
}
