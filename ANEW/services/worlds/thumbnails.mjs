import { maxThumbnailBytes, RequestError } from './http.mjs';

const pngSignature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const maxPending = 4;
const maxCached = 16;

function renderURL(endpoint) {
  const url = new URL(endpoint);
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if ((url.protocol !== 'https:' && !(local && url.protocol === 'http:')) ||
      url.username || url.password || url.search || url.hash) {
    throw new Error('Configure an HTTPS render base URL or a loopback HTTP URL');
  }
  url.pathname = `${url.pathname.replace(/\/+$/, '')}/`;
  return new URL('v1/render', url);
}

async function renderRemotely(url, token, scene) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token && { Authorization: `Bearer ${token}` }) },
    body: JSON.stringify(scene),
    redirect: 'error',
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok || response.headers.get('content-type')?.split(';')[0] !== 'image/png' ||
      Number(response.headers.get('content-length')) > maxThumbnailBytes) {
    await response.body?.cancel();
    throw new Error('Render service returned an invalid response');
  }

  const chunks = [];
  let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length;
    if (size > maxThumbnailBytes) throw new Error('Render service response exceeds the thumbnail limit');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, size);
}

export function createThumbnailProvider({ renderThumbnail, renderEndpoint, renderToken }) {
  const url = renderEndpoint && renderURL(renderEndpoint);
  const render = url ? (scene) => renderRemotely(url, renderToken, scene) : renderThumbnail;
  const cached = new Map();
  const pending = new Map();

  return async (scene) => {
    if (cached.has(scene)) {
      const png = cached.get(scene);
      cached.delete(scene);
      cached.set(scene, png);
      return png;
    }
    if (pending.has(scene)) return pending.get(scene);
    if (!render) throw new RequestError(503, 'Thumbnail service is unavailable');
    if (pending.size >= maxPending) throw new RequestError(503, 'Thumbnail service is busy');

    const request = Promise.resolve().then(() => render(scene)).then((image) => {
      if (!(image instanceof Uint8Array) || image.byteLength > maxThumbnailBytes) {
        throw new Error('Invalid thumbnail size');
      }
      const png = Buffer.from(image);
      if (!png.subarray(0, pngSignature.length).equals(pngSignature)) {
        throw new Error('Invalid thumbnail format');
      }
      if (cached.size >= maxCached) cached.delete(cached.keys().next().value);
      cached.set(scene, png);
      return png;
    }).catch(() => {
      throw new RequestError(502, 'Thumbnail rendering failed');
    }).finally(() => pending.delete(scene));
    pending.set(scene, request);
    return request;
  };
}
