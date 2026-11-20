// Opt-in integration fixture. Uses only a throwaway /tmp profile and loopback.
// node app/test/deepclub/start_real_host.mjs <path-to-dsh-node_modules> [http://127.0.0.1:PORT] [--tools-overlay]
// Stop with SIGTERM; the fixture stops DSH and removes its own temporary tree.
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { createServer as createPortServer } from 'node:net';
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

if (!process.argv[2]) throw new Error('Usage: node start_real_host.mjs <path-to-dsh-node_modules>');
const modules = resolve(process.argv[2]);
const suppliedOrigin = process.argv[3];
if (suppliedOrigin) {
  const uri = new URL(suppliedOrigin);
  if (uri.protocol !== 'http:' || uri.hostname !== '127.0.0.1' || !uri.port || uri.pathname !== '/' || uri.username || uri.password || uri.search || uri.hash) {
    throw new Error('Only an explicit loopback fixture origin is allowed');
  }
}
const entry = join(modules, '@deepseek-ai/dsh/lib/bin.js');
const packageInfo = JSON.parse(await readFile(join(modules, '@deepseek-ai/dsh/package.json'), 'utf8'));
if (packageInfo.version !== '0.2.2-rc.1') throw new Error('Expected DSH 0.2.2-rc.1');
const tmp = await realpath('/tmp');
const root = await realpath(await mkdtemp(join(tmp, 'deepclub-real-host-')));
const dshHome = join(root, 'dsh');
const profile = join(dshHome, 'profiles', 'mobile-auth-real');
const home = join(root, 'home');
await Promise.all([home, dshHome, join(root, 'tmp')].map(path => mkdir(path, { recursive: true, mode: 0o700 })));
let modelCalls = 0;
const mock = createServer((request, response) => {
  if (request.url === '/test-count') {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ modelCalls }));
    return;
  }
  modelCalls++;
  response.writeHead(503, { 'content-type': 'application/json' });
  response.end(JSON.stringify({ error: 'No model calls are allowed in this configuration test' }));
});
mock.listen(0, '127.0.0.1');
await once(mock, 'listening');
const mockOrigin = suppliedOrigin ?? `http://127.0.0.1:${mock.address().port}`;
const env = {
  PATH: `${dirname(process.execPath)}:/usr/bin:/bin`, HOME: home, DSH_HOME: dshHome,
  DSH_AGENTS_HOME: join(home, '.agents'), TMPDIR: join(root, 'tmp'), LANG: 'C.UTF-8',
  DEEPCLUB_TEST_ORIGIN: mockOrigin,
};
const initialized = spawnSync(process.execPath, [entry, '--profile', 'mobile-auth-real', '--from-default-profile', 'web', '--dump-config'], {
  cwd: root, env, encoding: 'utf8', timeout: 30000,
});
if (initialized.status !== 0) {
  await new Promise(resolveClose => mock.close(resolveClose));
  await cleanupRoot();
  throw new Error(`Isolated profile initialization failed: ${initialized.stderr}`);
}
const pluginPath = fileURLToPath(new URL('../../../runtime/deepclub-tools/src/index.js', import.meta.url));
// Profile-owned patch (not a --patch overlay): settings/mutate must write back.
const toolsPatch = { insert: [{ id: 'deepclub-tools', name: pathToFileURL(pluginPath).href }] };
const overlayMode = process.argv.includes('--tools-overlay');
const patch = [...(overlayMode ? [] : [toolsPatch]),
  { id: 'llm-pi-ai', config: { providers: { deepclub: { baseURL: `${mockOrigin}/v1` } } } },
  ...['llm-deepseek', 'llm-deepseek-account', 'web-search-deepseek', 'web-deepseek-api', 'session-telemetry-otel', 'dsh-media'].map(id => ({ id, disabled: true }))];
await writeFile(join(profile, 'cordis.patch.yml'), JSON.stringify(patch, null, 2), { mode: 0o600 });
const overlayPath = join(root, 'tools.patch.yml');
if (overlayMode) await writeFile(overlayPath, JSON.stringify([toolsPatch]), { mode: 0o600 });
const probe = createPortServer();
probe.listen(0, '127.0.0.1');
await once(probe, 'listening');
const port = probe.address().port;
await new Promise(resolveClose => probe.close(resolveClose));
const child = spawn(process.execPath, [entry, '--profile', 'mobile-auth-real', ...(overlayMode ? ['--patch', overlayPath] : []), '--host', '127.0.0.1', '--port', String(port), '--no-open'], {
  cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'],
});
const output = [];
let announced = false;
let shuttingDown = false;
const failTimer = setTimeout(() => {
  console.error('DSH did not announce readiness within 45 seconds');
  console.error(output.join('').replace(/token=[^\s&]+/g, 'token=<redacted>').slice(-6000));
  void stop(1);
}, 45000);
function onOutput(chunk) {
  output.push(String(chunk));
  if (announced) return;
  const line = output.join('').split('\n').find(value => value.startsWith('dsh web: http'));
  if (!line) return;
  announced = true;
  clearTimeout(failTimer);
  const url = new URL(line.slice('dsh web: '.length).trim());
  void writeFile(join(root, 'ready.json'), JSON.stringify({ version: packageInfo.version, baseUrl: url.origin,
    token: url.searchParams.get('token'), mockOrigin, root, profile, dshHome }), { mode: 0o600 }).then(() => {
    console.log(`READY info=${join(root, 'ready.json')} mock=${mockOrigin} engine=${url.origin} version=${packageInfo.version}`);
  });
}
child.stdout.on('data', onOutput);
child.stderr.on('data', onOutput);
child.once('exit', (code) => {
  if (!shuttingDown) {
    console.error(`DSH exited early with ${code}`);
    console.error(output.join('').replace(/token=[^\s&]+/g, 'token=<redacted>').slice(-6000));
    void stop(code || 1);
  }
});
async function stop(code = 0) {
  if (shuttingDown) return;
  shuttingDown = true;
  clearTimeout(failTimer);
  if (child.exitCode === null && child.signalCode === null) {
    child.kill('SIGTERM');
    let timeout;
    const ended = await Promise.race([once(child, 'exit').then(() => true), new Promise(resolveEnd => { timeout = setTimeout(() => resolveEnd(false), 8000); })]);
    clearTimeout(timeout);
    if (!ended) { child.kill('SIGKILL'); await once(child, 'exit'); }
  }
  await new Promise(resolveClose => mock.close(resolveClose));
  await cleanupRoot();
  console.log(`STOPPED modelCalls=${modelCalls}; removed isolated profile ${root}`);
  process.exit(code);
}
async function cleanupRoot() {
  const actual = await realpath(root);
  if (actual !== root || dirname(actual) !== tmp || !actual.startsWith(`${tmp}/deepclub-real-host-`)) throw new Error('Refusing unexpected cleanup target');
  await rm(actual, { recursive: true });
}
process.on('SIGTERM', () => { void stop(); });
process.on('SIGINT', () => { void stop(); });
