// Restricted binary adapter adapted from desktop b9719c4 output.ts (MIT).
// DSH 0.2.2-rc.1 has readBytes but no binary mutation seam. Reserve via its real
// write gate, then fill only that exact empty inode. No caller-supplied output path.
import { constants } from 'node:fs';
import { lstat, open, realpath, unlink } from 'node:fs/promises';
import { isAbsolute, join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { check, fail } from './errors.js';
import { imageMime, LIMITS } from './client.js';

const same = (a, b) => a?.ino === b?.ino && a?.dev === b?.dev;
function pathMentioned(text, path) {
  const escaped = path.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp('(?:^|[\\s@"\'`(<])' + escaped + '(?=$|[\\s"\'`)>，。;])').test(text);
}
export function latestUserText(session) {
  for (let i = session.seq - 1; i >= (session.firstLiveSeq ?? 0); i -= 1) {
    const event = session.eventAt(i);
    if (event?.type === 'user/message' && event.data?.source?.kind === 'user') {
      return event.data.content.filter(b => b.type === 'text').map(b => b.text).join('\n');
    }
  }
  return '';
}
export async function createWorkspace(ctx, exec, validate) {
  const signal = exec.signal, session = exec.agent.session;
  await validate();
  const cwd = await ctx.workingDirectory.ensure(exec.agent, signal);
  if (!isAbsolute(cwd)) fail('permission');
  const root = await ctx.fs.resolve(cwd, { signal });
  const native = ctx.fs.processPath(root);
  if (!isAbsolute(native) || ctx.fs.processPathFromHostPath(native) !== native || await realpath(native) !== resolve(native)) fail('filesystem');
  const rootIdentity = await lstat(native);
  if (!rootIdentity.isDirectory() || rootIdentity.isSymbolicLink()) fail('filesystem');
  const initialPolicy = ctx.sandboxPolicy.resolve({ session });

  async function guard() {
    await validate();
    const policy = ctx.sandboxPolicy.resolve({ session });
    if (!['workspace-write', 'danger-full-access'].includes(policy.mode)
      || policy.mode !== initialPolicy.mode || policy.workspaceRoot !== initialPolicy.workspaceRoot
      || ctx.workingDirectory.get(session) !== cwd) fail('permission');
    if (ctx.fs.processPath(await ctx.fs.resolve(cwd, { signal })) !== native || await realpath(native) !== native
      || !same(await lstat(native), rootIdentity)) fail('filesystem');
    if (policy.mode === 'workspace-write') {
      const allowed = await ctx.fs.resolve(policy.workspaceRoot, { signal });
      if (!ctx.fs.contains(allowed, root)) fail('permission');
    }
    await validate();
    return policy;
  }
  async function removeOwned(path, identity) {
    // Cleanup never follows a replaced parent or deletes another inode.
    if (await realpath(native) !== native || !same(await lstat(native), rootIdentity)) fail('filesystem');
    const info = await lstat(path).catch(error => { if (error.code === 'ENOENT') return; throw error; });
    if (info === undefined) return;
    if (!info.isFile() || info.isSymbolicLink() || !same(info, identity)) fail('filesystem');
    await unlink(path);
  }
  async function reserve(extension) {
    const policy = await guard();
    const path = join(native, `deepclub-${randomUUID()}.${extension}`);
    const target = await ctx.fs.resolve(path, { signal });
    if (!ctx.fs.contains(root, target) || ctx.fs.processPath(target) !== path) fail('permission');
    const intent = await ctx.waterfall('fs/write-intent', target, exec, () => undefined);
    if (intent && intent.kind !== 'createIfAbsent') fail('permission');
    await guard();
    const outcome = await ctx.fs.writeText(target, '', { kind: 'createIfAbsent' }, signal, policy);
    const identity = await lstat(path);
    try {
      if (!identity.isFile() || identity.isSymbolicLink() || identity.size !== 0
        || (await ctx.fs.stat(target, signal))?.version !== outcome.version) fail('filesystem');
      await guard();
      return { path, target, identity };
    } catch (error) { await removeOwned(path, identity); throw error; }
  }
  await guard();
  return {
    guard,
    async preflight() { const row = await reserve('tmp'); await removeOwned(row.path, row.identity); },
    async references(paths, userText) {
      const images = []; let size = 0;
      for (const path of paths) {
        // The model cannot nominate a directory, URL or another user's image.
        if (!isAbsolute(path) || !pathMentioned(userText, path) || path.includes('\0')) fail('reference');
        await guard();
        const target = await ctx.fs.resolve(path, { signal });
        if (!ctx.fs.contains(root, target) || (await ctx.fs.lstat(path, {}, signal))?.type !== 'file') fail('reference');
        const before = await ctx.fs.stat(target, signal);
        if (before?.type !== 'file') fail('reference');
        const bytes = Buffer.from(await ctx.fs.readBytes(target, signal, LIMITS.reference - size));
        if ((await ctx.fs.stat(target, signal))?.version !== before.version) fail('reference');
        size += bytes.length;
        if (!bytes.length || size > LIMITS.reference) fail('reference');
        images.push({ bytes, mime: imageMime(bytes), path, target, version: before.version });
      }
      return images;
    },
    async validateReferences(images) {
      await guard();
      for (const image of images) {
        const target = await ctx.fs.resolve(image.path, { signal });
        if (target.targetKey !== image.target.targetKey || (await ctx.fs.stat(target, signal))?.version !== image.version) fail('reference');
      }
    },
    async save(asset) {
      const extension = ({ 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp', 'video/mp4': 'mp4' })[asset.mime];
      if (!extension || !(asset.bytes instanceof Uint8Array)) fail('response');
      const row = await reserve(extension);
      let done = false;
      try {
        await guard();
        const handle = await open(row.path, constants.O_WRONLY | constants.O_NOFOLLOW);
        try {
          const current = await handle.stat();
          if (!current.isFile() || current.size !== 0 || !same(current, row.identity)) fail('filesystem');
          await guard();
          await handle.writeFile(asset.bytes, { signal });
          await handle.sync();
          await guard();
          done = true;
        } finally { await handle.close(); }
      } finally { if (!done) await removeOwned(row.path, row.identity); }
      return { path: row.path, mime: asset.mime, bytes: asset.bytes.length };
    },
    async saveJSON(value) {
      const policy = await guard();
      const path = join(native, `deepclub-${randomUUID()}.json`);
      const target = await ctx.fs.resolve(path, { signal });
      if (!ctx.fs.contains(root, target) || ctx.fs.processPath(target) !== path) fail('permission');
      const intent = await ctx.waterfall('fs/write-intent', target, exec, () => undefined);
      if (intent && intent.kind !== 'createIfAbsent') fail('permission');
      check(signal); await guard();
      const content = JSON.stringify(value);
      await ctx.fs.writeText(target, content, { kind: 'createIfAbsent' }, signal, policy);
      return { path, mime: 'application/json', bytes: Buffer.byteLength(content) };
    },
  };
}
