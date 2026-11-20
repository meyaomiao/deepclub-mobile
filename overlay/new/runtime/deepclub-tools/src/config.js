import z from '@deepseek-ai/schemastery';
import { fail } from './errors.js';

export const Config = z.object({
  catalog: z.any().default({}).volatile().description('深云登录同步的完整设备 agent-config；退出时清空。'),
});
export const KEY = 'DEEPCLUB_API_KEY';
export const TOOLS = Object.freeze({
  deepclub_generate_image: { grant: 'image_generation', category: 'image', endpoint: '/v1/images/generations' },
  deepclub_edit_image: { grant: 'image_editing', category: 'image', endpoint: '/v1/images/edits' },
  deepclub_generate_video: { grant: 'video', category: 'video' },
  deepclub_embed: { grant: 'embedding', category: 'embedding', endpoint: '/v1/embeddings' },
});
export const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const text = value => typeof value === 'string' && value.trim().length > 0;

// baseURL is absent from tool arguments. A trusted debug launcher or an
// in-process test may inject one exact loopback/emulator-host origin. It is not
// a settings field and an unapproved catalog URL cannot enable this exception.
export function controlledTestOrigin(value) {
  if (value === undefined) return undefined;
  let url;
  try { url = new URL(value); } catch { fail('unsafe_url'); }
  if (url.protocol !== 'http:' || !['127.0.0.1', '[::1]', '10.0.2.2'].includes(url.hostname)
    || url.username || url.password || url.search || url.hash || url.pathname !== '/') fail('unsafe_url');
  return url.origin;
}
export function baseURL(catalog, loopbackBaseURL) {
  const testOrigin = controlledTestOrigin(loopbackBaseURL);
  let url;
  try { url = new URL(catalog.base_url ?? 'https://deepclub.net'); } catch { fail('unsafe_url'); }
  const value = url.href.replace(/\/$/, '');
  if (value !== 'https://deepclub.net' && value !== testOrigin) fail('unsafe_url');
  return testOrigin ?? 'https://deepclub.net';
}
export function snapshot(config) {
  const value = config.catalog?.get?.();
  if (!object(value)) fail('authorization');
  // Copy volatile data: a live update cannot mutate an already-approved payload.
  return JSON.parse(JSON.stringify(value));
}
export function endpointFor(def, model, media) {
  if (def.endpoint) return def.endpoint;
  const protocol = media?.video_protocol;
  if (protocol === 'openai') return '/v1/videos';
  if (protocol === 'generations') return '/v1/video/generations';
  // Legacy publications may have no media spec. An unambiguous endpoint is evidence.
  if (!protocol) {
    const endpoints = (model.endpoints ?? []).filter(p => ['/v1/videos', '/v1/video/generations'].includes(p));
    if (endpoints.length === 1) return endpoints[0];
  }
  return undefined;
}
export function modelsFor(catalog, toolName) {
  const def = TOOLS[toolName], grant = catalog.tools?.[def.grant];
  if (catalog.api_key_env !== KEY || grant?.enabled !== true || !Array.isArray(grant.model_ids)
    || !Array.isArray(catalog.models)) return [];
  return catalog.models.filter(model => object(model) && text(model.id) && model.category === def.category
    && grant.model_ids.includes(model.id) && Array.isArray(model.endpoints)
    && (model.specifications?.length ? model.specifications : [{ media: model.media }]).some(spec => {
      const endpoint = endpointFor(def, model, spec.media ?? model.media);
      return endpoint && model.endpoints.includes(endpoint);
    }));
}
const commonArgs = ['model', 'specification', 'user_intent'];
const mediaArgs = ['prompt', 'size', 'quality', 'ratio', 'seconds', 'n'];

/** Fixed parameters come from the selected published specification, never a model-name heuristic. */
export function selectRequest(catalog, toolName, args, loopbackBaseURL) {
  const def = TOOLS[toolName];
  const allowed = new Set([...commonArgs, ...(def.category === 'embedding' ? ['input'] : mediaArgs),
    ...(['deepclub_edit_image', 'deepclub_generate_video'].includes(toolName) ? ['references'] : [])]);
  if (!object(args) || Object.keys(args).some(k => !allowed.has(k)) || !text(args.model)
    || !text(args.user_intent) || args.user_intent.length > 2048) fail('request');
  const models = modelsFor(catalog, toolName);
  const model = models.find(m => m.id === args.model);
  if (!model || models.filter(m => m.id === model.id).length !== 1) fail('authorization');
  const specs = model.specifications ?? [];
  if (!Array.isArray(specs)) fail('authorization');
  const spec = args.specification === undefined
    ? (specs.length <= 1 ? specs[0] : undefined)
    : specs.find(s => s.key === args.specification);
  if ((specs.length > 1 && !spec) || (args.specification !== undefined && !spec)) fail('authorization');
  const media = spec?.media ?? model.media ?? {};
  const pinned = spec?.parameters ?? model.parameters ?? {};
  if (!object(media) || !object(pinned)) fail('authorization');
  const endpoint = endpointFor(def, model, media);
  if (!endpoint || !model.endpoints.includes(endpoint)) fail('authorization');
  const body = { model: model.id };
  if (def.category === 'embedding') {
    const inputs = Array.isArray(args.input) ? args.input : [args.input];
    if (!inputs.length || inputs.length > 128 || inputs.some(i => !text(i))
      || Buffer.byteLength(JSON.stringify(inputs)) > 512 * 1024) fail('request');
    if (Object.keys(pinned).length) fail('authorization'); // Unknown embedding parameters must not be guessed.
    body.input = args.input;
  } else {
    if (!text(args.prompt) || Buffer.byteLength(args.prompt) > 32000) fail('request');
    body.prompt = args.prompt;
    const fields = def.category === 'image' ? ['size', 'quality'] : ['size', 'seconds', 'duration', 'aspect_ratio'];
    if (Object.keys(pinned).some(k => !fields.includes(k)) || Object.values(pinned).some(v => !text(v))) fail('authorization');
    Object.assign(body, pinned);
    if (body.duration !== undefined) body.duration = Number(body.duration);
    const maxImages = media.max_images || 1;
    const n = args.n ?? 1;
    if (!Number.isInteger(n) || n < 1 || n > Math.min(maxImages, 4) || (def.category === 'video' && n !== 1)) fail('request');
    if (def.category === 'image') body.n = n;
    const ratios = media.ratios ?? [];
    if (!Array.isArray(ratios)) fail('authorization');
    const ratioKey = endpoint === '/v1/video/generations' ? 'aspect_ratio' : 'size';
    if (args.ratio !== undefined) {
      let ratio = ratios.find(r => r.ratio === args.ratio);
      if (!ratio && media.custom_ratios === true && ratioKey === 'aspect_ratio' && /^[1-9]\d?:[1-9]\d?$/.test(args.ratio)) ratio = { ratio: args.ratio };
      if (!ratio) fail('request');
      if (ratio.ratio !== 'auto') body[ratioKey] = ratioKey === 'size' ? ratio.size : ratio.ratio;
      else delete body[ratioKey];
    } else if (ratios.length && !ratios.some(r => r.ratio === 'auto')) {
      body[ratioKey] = ratioKey === 'size' ? ratios[0].size : ratios[0].ratio;
    }
    for (const field of ['size', 'quality']) {
      if (args[field] === undefined) continue;
      if (!text(args[field])) fail('request');
      if (field === 'size' && args.ratio === undefined && !pinned.size) {
        const parts = /^(\d+)x(\d+)$/.exec(args.size)?.slice(1).map(Number);
        const custom = parts && media.custom_ratio_long_edge > 0 && Math.max(...parts) === media.custom_ratio_long_edge
          && Math.min(...parts) >= 64 && parts.every(n => n % 16 === 0);
        if (!ratios.some(r => r.size === args.size) && !custom) fail('request');
        body.size = args.size;
      } else if (String(body[field]) !== args[field]) fail('request');
    }
    if (args.seconds !== undefined) {
      if (def.category !== 'video' || !Number.isInteger(args.seconds) || args.seconds < 1) fail('request');
      const key = endpoint === '/v1/videos' ? 'seconds' : 'duration';
      const expected = pinned[key] ?? media.duration_seconds;
      if (!expected || Number(expected) !== args.seconds) fail('request');
      body[key] = key === 'seconds' ? String(args.seconds) : args.seconds;
    } else if (def.category === 'video' && media.duration_seconds) {
      const key = endpoint === '/v1/videos' ? 'seconds' : 'duration';
      if (body[key] !== undefined && Number(body[key]) !== media.duration_seconds) fail('authorization');
      body[key] = key === 'seconds' ? String(media.duration_seconds) : media.duration_seconds;
    }
    if (def.category === 'image' && (args.seconds !== undefined)) fail('request');
  }
  // The sale gate uses resolution as the discriminator before stripping it;
  // a specification key itself is not a public request parameter.
  if (spec && text(media.resolution)) body.resolution = media.resolution;
  const references = args.references ?? [];
  const maxRefs = toolName === 'deepclub_edit_image' ? (media.image_protocol ? 1 : 16)
    : media.reference_images === true ? (endpoint === '/v1/videos' ? 1 : 2) : 0;
  if (!Array.isArray(references) || references.length > maxRefs || references.some(p => !text(p))
    || (toolName === 'deepclub_edit_image' && !references.length)) fail('reference');
  return { toolName, category: def.category, base: baseURL(catalog, loopbackBaseURL), endpoint, body,
    model: model.id, specification: spec?.key, media, references, userIntent: args.user_intent,
    price: spec?.price ?? model.price };
}
