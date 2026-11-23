import { once } from 'node:events';
import { createServer, STATUS_CODES } from 'node:http';
import { validateScene, validateWorldId } from '../../shared/scene.mjs';
import { createAuthorization, readSceneBody, RequestError, sendJson } from './http.mjs';
import { createRooms } from './rooms.mjs';
import { openWorldStore } from './store.mjs';
import { createThumbnailProvider } from './thumbnails.mjs';

function requestUrl(request) {
  if (!request.url?.startsWith('/') || request.url.startsWith('//')) {
    throw new RequestError(400, 'Invalid request URL');
  }
  return new URL(request.url, 'http://localhost');
}

function worldId(value) {
  try {
    return validateWorldId(value);
  } catch {
    throw new RequestError(400, 'Invalid world identifier');
  }
}

function parseScene(body) {
  try {
    return validateScene(body);
  } catch (error) {
    throw new RequestError(400, error.message);
  }
}

function method(request, response, valid) {
  if (valid.includes(request.method)) return;
  response.setHeader('Allow', valid.join(', '));
  throw new RequestError(405, 'Method not allowed');
}

export async function startWorldService({
  host = '127.0.0.1',
  port = 0,
  readToken,
  writeToken,
  dataDir,
  renderThumbnail,
  renderEndpoint,
  renderToken,
  browserOrigin,
} = {}) {
  if (typeof host !== 'string' || !host || !Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error('Configure a valid world service host and port');
  }
  if (browserOrigin && new URL(browserOrigin).origin !== browserOrigin) {
    throw new Error('Configure the browser origin without a path or trailing slash');
  }
  const authorize = createAuthorization(readToken, writeToken);
  const thumbnail = createThumbnailProvider({ renderThumbnail, renderEndpoint, renderToken });
  const store = await openWorldStore(dataDir);
  const rooms = createRooms();
  let closing;

  async function handle(request, response) {
    const path = requestUrl(request).pathname;
    if (path === '/healthz') {
      method(request, response, ['GET']);
      sendJson(response, 200, { status: 'ok', service: 'pot-worlds' });
      return;
    }
    if (path === '/v1/worlds') {
      method(request, response, ['GET']);
      authorize(request.headers.authorization);
      sendJson(response, 200, await store.list());
      return;
    }

    const match = /^\/v1\/worlds\/([^/]+)(\/thumbnail)?$/.exec(path);
    if (!match) throw new RequestError(404, 'Route not found');
    const [, segment, isThumbnail] = match;
    const id = worldId(segment);
    if (!isThumbnail && request.method === 'PUT') {
      authorize(request.headers.authorization, true);
      const scene = parseScene(await readSceneBody(request));
      if (id !== scene.id) throw new RequestError(400, 'World identifiers must match');
      await store.put(scene);
      rooms.disconnect(id);
      sendJson(response, 200, scene);
      return;
    }

    method(request, response, isThumbnail ? ['GET'] : ['GET', 'PUT']);
    authorize(request.headers.authorization);
    const scene = await store.get(id);
    if (!scene) throw new RequestError(404, 'World not found');
    if (!isThumbnail) {
      sendJson(response, 200, scene);
      return;
    }
    const image = await thumbnail(scene);
    response.writeHead(200, {
      'Content-Type': 'image/png',
      'Content-Length': image.length,
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    });
    response.end(image);
  }

  const server = createServer({
    connectionsCheckingInterval: 2500,
    requestTimeout: 15_000,
    headersTimeout: 10_000,
    keepAliveTimeout: 5000,
    maxHeaderSize: 8192,
  }, (request, response) => {
    handle(request, response).catch((error) => {
      if (response.destroyed || response.writableEnded) return;
      if (response.headersSent) {
        response.destroy();
        return;
      }
      if (!request.complete) response.setHeader('Connection', 'close');
      if (error instanceof RequestError) {
        sendJson(response, error.status, { error: error.message });
        return;
      }
      console.error('Pot world service request failed', error);
      sendJson(response, 500, { error: 'World service request failed' });
    });
  });
  server.maxConnections = 256;
  server.maxHeadersCount = 32;
  server.maxRequestsPerSocket = 500;

  server.on('upgrade', (request, socket, head) => {
    const onSocketError = () => socket.destroy();
    socket.on('error', onSocketError);
    socket.pause();
    const upgrade = async () => {
      const url = requestUrl(request);
      if (url.pathname !== '/v1/session') throw new RequestError(404, 'Route not found');
      if (request.headers.origin && request.headers.origin !== browserOrigin) {
        throw new RequestError(403, 'Browser origin is not allowed');
      }
      authorize(request.headers.authorization);
      const scene = await store.get(worldId(url.searchParams.get('world')));
      if (closing) throw new RequestError(503, 'World service is shutting down');
      if (!scene) throw new RequestError(404, 'World not found');
      if (socket.destroyed) return;
      rooms.upgrade(request, socket, head, scene);
      socket.removeListener('error', onSocketError);
      socket.resume();
    };
    upgrade().catch((error) => {
      if (socket.destroyed) return;
      const status = error instanceof RequestError ? error.status : 500;
      if (status === 500) console.error('Pot world service upgrade failed', error);
      const authHeader = status === 401 ? 'WWW-Authenticate: Bearer\r\n' : '';
      const head = `HTTP/1.1 ${status} ${STATUS_CODES[status]}\r\nConnection: close\r\n${authHeader}Content-Length: 0\r\n\r\n`;
      socket.end(head, () => socket.destroy());
    });
  });

  try {
    server.listen(port, host);
    await once(server, 'listening');
  } catch (error) {
    await rooms.close();
    throw error;
  }
  const address = server.address();
  const authority = address.address.includes(':') ? `[${address.address}]` : address.address;

  return {
    url: `http://${authority}:${address.port}`,
    close() {
      closing ??= (async () => {
        const stopped = new Promise((resolve) => server.close(resolve));
        const timer = setTimeout(() => server.closeAllConnections(), 2500);
        timer.unref();
        await Promise.all([stopped, rooms.close()]);
        clearTimeout(timer);
        await store.close();
      })();
      return closing;
    },
  };
}
