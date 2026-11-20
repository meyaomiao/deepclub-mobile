// Adapted from deepclub-desktop b9719c4 media-client.ts (MIT); no UI or gateway code.
// Every invocation performs one HTTP request. In particular a charged POST is NEVER retried.
import { request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { lookup } from 'node:dns';
import { BlockList, isIP } from 'node:net';
import { check, fail, ToolError } from './errors.js';

export const LIMITS = Object.freeze({ reference: 20 * 1024 * 1024, json: 32 * 1024 * 1024, image: 20 * 1024 * 1024, video: 128 * 1024 * 1024 });
const privateIPs = new BlockList();
for (const [ip, prefix] of [['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8], ['169.254.0.0', 16], ['172.16.0.0', 12], ['192.0.0.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15], ['224.0.0.0', 4], ['240.0.0.0', 4]]) privateIPs.addSubnet(ip, prefix, 'ipv4');
for (const [ip, prefix] of [['::', 96], ['::ffff:0:0', 96], ['fc00::', 7], ['fe80::', 10], ['ff00::', 8]]) privateIPs.addSubnet(ip, prefix, 'ipv6');
function isPublic(address) { const type = isIP(address); return type !== 0 && !privateIPs.check(address, type === 6 ? 'ipv6' : 'ipv4'); }
export function safeURL(value, testBase) {
  let url;
  try { url = new URL(value); } catch { fail('unsafe_url'); }
  if (url.username || url.password || url.hash) fail('unsafe_url');
  if (testBase && url.origin === testBase) return url;
  const host = url.hostname.replace(/^\[|\]$/g, '');
  if (url.protocol !== 'https:' || (url.port && url.port !== '443') || host === 'localhost' || host.endsWith('.localhost')
    || host.endsWith('.local') || (!isIP(host) && !host.includes('.')) || (isIP(host) && !isPublic(host))) fail('unsafe_url');
  return url;
}
function publicLookup(host, options, callback) {
  lookup(host, { ...options, all: true }, (error, addresses) => {
    if (error) return callback(error);
    if (!addresses.length || addresses.some(row => !isPublic(row.address))) return callback(new ToolError('unsafe_url'));
    // Resolve once, then connect to the checked address; avoid a separate DNS lookup by fetch.
    if (options.all) callback(null, addresses);
    else callback(null, addresses[0].address, addresses[0].family);
  });
}
export async function requestBytes(urlValue, { key, body, signal, maxBytes = LIMITS.json, testBase } = {}) {
  check(signal);
  const url = safeURL(urlValue, testBase);
  const headers = { accept: '*/*', 'accept-encoding': 'identity' };
  if (key !== undefined) headers.authorization = 'Bearer ' + key;
  let bytes;
  if (body instanceof FormData) {
    const encoded = new Request(url, { method: 'POST', body });
    headers['content-type'] = encoded.headers.get('content-type');
    bytes = Buffer.from(await encoded.arrayBuffer());
  } else if (body !== undefined) {
    headers['content-type'] = 'application/json';
    bytes = Buffer.from(JSON.stringify(body));
  }
  if (bytes) headers['content-length'] = String(bytes.length);
  check(signal);
  return new Promise((resolve, reject) => {
    const request = (url.protocol === 'http:' ? httpRequest : httpsRequest)(url, {
      method: body === undefined ? 'GET' : 'POST', headers, signal,
      ...(testBase && url.origin === testBase ? {} : { lookup: publicLookup }),
    }, response => {
      const parts = []; let size = 0;
      response.on('data', chunk => {
        size += chunk.length;
        if (size > maxBytes) { response.destroy(new ToolError('response')); return; }
        parts.push(chunk);
      });
      response.on('error', reject);
      response.on('end', () => {
        const status = response.statusCode;
        // No redirects, no upstream error text (it may contain a key or signed URL).
        if (status === 401 || status === 403) reject(new ToolError('credential'));
        else if (status < 200 || status >= 300) reject(new ToolError('http'));
        else resolve(Buffer.concat(parts));
      });
    });
    request.on('error', reject);
    request.end(bytes);
  });
}
export function imageMime(bytes) {
  const signature = Buffer.from(bytes.subarray(0, 12));
  if (signature.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return 'image/png';
  if (bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) return 'image/jpeg';
  if (signature.toString('ascii', 0, 4) === 'RIFF' && signature.toString('ascii', 8, 12) === 'WEBP') return 'image/webp';
  fail('response');
}
const parse = bytes => {
  try { const value = JSON.parse(bytes.toString('utf8')); if (value && typeof value === 'object' && !Array.isArray(value)) return value; } catch { /* static error below */ }
  fail('response');
};
export const taskID = id => { if (typeof id !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$/.test(id)) fail('response'); return id; };

export function createClient(request, context) {
  const testBase = context.loopbackBaseURL === undefined ? undefined : request.base;
  async function bytes(path, body, maxBytes = LIMITS.json, authenticated = true) {
    await context.validate();
    const key = authenticated ? await context.resolveKey() : undefined;
    await context.validate();
    return requestBytes(path, { key, body, signal: context.signal, maxBytes, testBase });
  }
  const json = async (path, body) => parse(await bytes(request.base + path, body));
  async function download(url, maxBytes) {
    // Result/CDN links never get the device key, even on the same origin.
    return bytes(url, undefined, maxBytes, false);
  }
  function payload(references) {
    if (request.endpoint === '/v1/images/edits' || request.endpoint === '/v1/videos') {
      const form = new FormData();
      for (const [key, value] of Object.entries(request.body)) form.set(key, String(value));
      references.forEach((ref, i) => form.append(request.endpoint === '/v1/videos' ? 'input_reference'
        : references.length === 1 ? 'image' : 'image[]', new Blob([ref.bytes], { type: ref.mime }), `input-${i + 1}.${ref.mime === 'image/jpeg' ? 'jpg' : ref.mime.slice(6)}`));
      return form;
    }
    return { ...request.body, ...(references.length ? { images: references.map(ref => `data:${ref.mime};base64,${ref.bytes.toString('base64')}`) } : {}) };
  }
  return {
    async image(references) {
      const response = await json(request.endpoint, payload(references));
      if (!Array.isArray(response.data) || response.data.length !== request.body.n) fail('response');
      const images = [];
      for (const item of response.data) {
        let data;
        if (typeof item?.b64_json === 'string') {
          if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(item.b64_json)) fail('response');
          data = Buffer.from(item.b64_json, 'base64');
        } else if (typeof item?.url === 'string') data = await download(item.url, LIMITS.image);
        else fail('response');
        if (!data.length || data.length > LIMITS.image) fail('response');
        images.push({ bytes: data, mime: imageMime(data) });
      }
      return images;
    },
    async embed() {
      const response = await json(request.endpoint, request.body);
      const count = Array.isArray(request.body.input) ? request.body.input.length : 1;
      const rows = response.data;
      if (!Array.isArray(rows) || rows.length !== count || rows.some(row => !Number.isInteger(row.index) || row.index < 0 || row.index >= count
        || !Array.isArray(row.embedding) || !row.embedding.length || row.embedding.some(n => typeof n !== 'number' || !Number.isFinite(n)))
        || new Set(rows.map(row => row.index)).size !== count) fail('response');
      return { model: request.model, data: rows.map(({ index, embedding }) => ({ index, embedding })) };
    },
    async submitVideo(references) {
      const response = await json(request.endpoint, payload(references));
      const id = request.endpoint === '/v1/videos' ? response.id
        : response.task_id ?? response.id ?? (response.code === 'success'
          ? (typeof response.data === 'string' ? response.data : response.data?.task_id) : undefined);
      return taskID(id);
    },
    async videoStatus(id) {
      taskID(id);
      const response = await json(request.endpoint + '/' + encodeURIComponent(id));
      const generic = request.endpoint === '/v1/video/generations';
      const task = generic ? (response.code === 'success' ? response.data : undefined) : response;
      if (!task || taskID(generic ? task.task_id : task.id) !== id) fail('response');
      const state = String(task.status).toLowerCase();
      if (['failed', 'failure', 'cancelled', 'canceled'].includes(state)) fail('task_failed');
      if (['success', 'completed', 'succeeded'].includes(state)) {
        const data = generic ? await download(task.result_url, LIMITS.video)
          : await bytes(request.base + request.endpoint + '/' + encodeURIComponent(id) + '/content', undefined, LIMITS.video);
        if (data.length < 12 || data.toString('ascii', 4, 8) !== 'ftyp') fail('response');
        return { done: true, asset: { bytes: data, mime: 'video/mp4' } };
      }
      if (!['not_start', 'submitted', 'queued', 'pending', 'in_progress', 'processing', 'running'].includes(state)) fail('response');
      return { done: false, state };
    },
  };
}
