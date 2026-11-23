import { createHash, timingSafeEqual } from 'node:crypto';
import { MAX_SCENE_BYTES } from '../../shared/scene.mjs';

export const maxThumbnailBytes = 1024 * 1024;

export class RequestError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function digest(value) {
  return createHash('sha256').update(value).digest();
}

export function createAuthorization(readToken, writeToken) {
  for (const token of [readToken, writeToken]) {
    if (token !== undefined && (typeof token !== 'string' || !/^[\x21-\x7e]{1,512}$/.test(token))) {
      throw new Error('Configure each access token as a single nonempty ASCII value');
    }
  }

  const reader = readToken && digest(readToken);
  const writer = writeToken && digest(writeToken);
  return (header, write = false) => {
    if (write && !writer) {
      throw new RequestError(403, 'World publishing is disabled');
    }
    if (!write && !reader) return;
    const match = /^Bearer ([\x21-\x7e]{1,512})$/i.exec(header ?? '');
    const supplied = match && digest(match[1]);
    if (supplied && writer && timingSafeEqual(supplied, writer)) return;
    if (!write && supplied && timingSafeEqual(supplied, reader)) return;
    throw new RequestError(401, 'Valid credentials are required');
  };
}

export function sendJson(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...(status === 401 && { 'WWW-Authenticate': 'Bearer' }),
  });
  response.end(body);
}

export async function readSceneBody(request) {
  const type = request.headers['content-type']?.split(';', 1)[0].trim().toLowerCase();
  if (type !== 'application/json') {
    throw new RequestError(415, 'Use application/json for the world scene');
  }
  if (Number(request.headers['content-length']) > MAX_SCENE_BYTES) {
    request.resume();
    throw new RequestError(413, 'World scene is too large');
  }

  // Pausing instead of destroying an oversized request lets the server
  // finish writing its 413 response before the connection closes.
  const body = await new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    const timer = setTimeout(() => fail(408, 'Timed out reading the world scene'), 10_000);
    timer.unref();
    function stopReading() {
      clearTimeout(timer);
      request.off('data', onData);
      request.off('end', onEnd);
      request.off('close', onClose);
    }
    function fail(status, message) {
      stopReading();
      request.pause();
      reject(new RequestError(status, message));
    }
    function onData(chunk) {
      size += chunk.length;
      if (size > MAX_SCENE_BYTES) fail(413, 'World scene is too large');
      else chunks.push(chunk);
    }
    function onEnd() {
      stopReading();
      resolve(Buffer.concat(chunks, size));
    }
    function onClose() {
      fail(400, 'World scene upload was interrupted');
    }

    request.once('error', onClose);
    request.once('close', onClose);
    request.once('end', onEnd);
    request.on('data', onData);
  });

  try {
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(body));
  } catch {
    throw new RequestError(400, 'World scene must contain valid JSON');
  }
}
