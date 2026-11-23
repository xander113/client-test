import { randomBytes } from 'node:crypto';
import { startRenderService } from '../render/service.mjs';
import { startWorldService } from './service.mjs';

const env = process.env;
let embeddedRenderer;
try {
  let renderEndpoint = env.POT_RENDER_ENDPOINT;
  let renderToken = env.POT_RENDER_TOKEN;
  if (!renderEndpoint) {
    renderToken = randomBytes(32).toString('hex');
    embeddedRenderer = await startRenderService({ token: renderToken });
    renderEndpoint = embeddedRenderer.url;
  }
  const server = await startWorldService({
    host: env.POT_WORLD_HOST ?? '127.0.0.1',
    port: Number(env.POT_WORLD_PORT ?? '4831'),
    dataDir: env.POT_WORLD_DATA_DIR,
    readToken: env.POT_WORLD_READ_TOKEN,
    writeToken: env.POT_WORLD_WRITE_TOKEN,
    browserOrigin: env.POT_WORLD_BROWSER_ORIGIN,
    renderEndpoint,
    renderToken,
  });
  console.log(`Pot world service listening at ${server.url}`);
  let shutdownPromise;
  const shutdown = () => {
    shutdownPromise ??= server.close()
      .finally(() => embeddedRenderer?.close())
      .catch((error) => {
        console.error('Pot world service shutdown failed', error);
        process.exitCode = 1;
      });
  };
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
} catch (error) {
  console.error('Could not start the Pot world service', error);
  await embeddedRenderer?.close().catch((closeError) => {
    console.error('PotRenderService cleanup failed', closeError);
  });
  process.exitCode = 1;
}
