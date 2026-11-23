import WebSocket from 'ws';
import { MAX_SCENE_BYTES, validateScene, validateWorldId } from '../shared/scene.mjs';

const TIMEOUT = 8_000;
const MAX_THUMBNAIL_BYTES = 1024 * 1024;

function endpoint(value) {
  const url = new URL(value);
  const loopback = ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname);
  if ((url.protocol !== 'https:' && !(loopback && url.protocol === 'http:')) ||
      url.username || url.password || url.search || url.hash) {
    throw new Error('Pot world endpoints require HTTPS, or HTTP on loopback, and no embedded credentials.');
  }
  if (!url.pathname.endsWith('/')) url.pathname += '/';
  return url;
}

async function readResponse(response, limit) {
  const chunks = [];
  let size = 0;
  for await (const chunk of response.body ?? []) {
    size += chunk.length;
    if (size > limit) throw new Error('The world service sent too much data.');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, size);
}

function auth(token) {
  return token ? { Authorization: `Bearer ${token}` } : {};
}

export class WorldApi {
  constructor(base, { readToken, writeToken, mode = 'local' } = {}) {
    this.base = endpoint(base);
    this.readToken = readToken;
    this.writeToken = writeToken;
    this.mode = mode;
  }

  async request(path, { method = 'GET', document, limit = MAX_SCENE_BYTES, timeout = TIMEOUT } = {}) {
    const writing = method === 'PUT';
    const headers = auth(writing ? this.writeToken : this.readToken);
    const signal = AbortSignal.timeout(timeout);
    let body;
    if (document !== undefined) {
      body = JSON.stringify(document);
      headers['Content-Type'] = 'application/json';
    }
    const response = await fetch(new URL(path, this.base), {
      method, headers, body, signal, redirect: 'error',
    }).catch(() => { throw new Error('Pot could not reach the world service.'); });
    if (!response.ok) {
      await response.body?.cancel();
      if (response.status === 401 || response.status === 403) {
        throw new Error('The world service denied access.');
      }
      if (response.status === 404) throw new Error('This world could not be found.');
      throw new Error(`The world service returned an error (${response.status}).`);
    }
    return { data: await readResponse(response, limit), contentType: response.headers.get('content-type') };
  }

  async health() {
    await this.request('healthz', { limit: 4096, timeout: 2000 });
  }

  async list() {
    const { data } = await this.request('v1/worlds');
    const worlds = JSON.parse(data.toString('utf8'));
    if (!Array.isArray(worlds) || worlds.length > 1000) throw new Error('The world catalog is invalid.');
    return worlds.map(({ id, name, description }) => {
      if (typeof name !== 'string' || name.length > 80 ||
          typeof description !== 'string' || description.length > 400) {
        throw new Error('The world catalog contains an invalid entry.');
      }
      return { id: validateWorldId(id), name, description };
    });
  }

  async load(id) {
    const { data } = await this.request(`v1/worlds/${validateWorldId(id)}`);
    const scene = validateScene(JSON.parse(data.toString('utf8')));
    if (scene.id !== id) throw new Error('The world service returned a different world.');
    return scene;
  }

  async publish(input) {
    const scene = validateScene(input);
    if (this.mode === 'hosted' && !this.writeToken) {
      throw new Error('The hosted world service needs a Studio publishing credential.');
    }
    await this.request(`v1/worlds/${scene.id}`, { method: 'PUT', document: scene });
    return { id: scene.id };
  }

  async thumbnail(id) {
    const { data, contentType } = await this.request(`v1/worlds/${validateWorldId(id)}/thumbnail`,
      { limit: MAX_THUMBNAIL_BYTES });
    if (contentType?.split(';')[0] !== 'image/png') throw new Error('The thumbnail is unavailable.');
    return `data:image/png;base64,${data.toString('base64')}`;
  }

  connect(id) {
    const url = new URL('v1/session', this.base);
    url.protocol = this.base.protocol === 'https:' ? 'wss:' : 'ws:';
    url.searchParams.set('world', validateWorldId(id));
    return new WebSocket(url, {
      headers: auth(this.readToken),
      handshakeTimeout: TIMEOUT,
      maxPayload: 64 * 1024,
      perMessageDeflate: false,
    });
  }
}

export function isPose(pose) {
  return pose && Number.isFinite(pose.x) && Math.abs(pose.x) <= 320 &&
    Number.isFinite(pose.y) && pose.y >= -40 && pose.y <= 330 &&
    Number.isFinite(pose.z) && Math.abs(pose.z) <= 320 &&
    Number.isFinite(pose.yaw) && Math.abs(pose.yaw) <= 1000;
}

export function decodeSessionMessage(data) {
  const message = JSON.parse(data.toString());
  if (message?.type === 'welcome' && typeof message.id === 'string' && message.id.length <= 64) {
    return { type: 'welcome', id: message.id };
  }
  if (message?.type !== 'state' || !Array.isArray(message.players) || message.players.length > 100) return null;
  return {
    type: 'state',
    players: message.players.filter((player) => isPose(player) &&
      typeof player.id === 'string' && player.id.length <= 64 &&
      typeof player.name === 'string' && player.name.length <= 80 &&
      typeof player.color === 'string' && /^#[0-9a-f]{6}$/iu.test(player.color))
      .map(({ id, name, color, x, y, z, yaw }) => ({ id, name, color, x, y, z, yaw })),
  };
}
