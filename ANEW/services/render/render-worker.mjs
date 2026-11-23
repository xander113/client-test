import { parentPort } from 'node:worker_threads'
import { renderThumbnail } from './thumbnail.mjs'

parentPort.on('message', scene => {
  try {
    const png = Uint8Array.from(renderThumbnail(scene))
    parentPort.postMessage(png, [png.buffer])
  } catch {
    parentPort.postMessage(null)
  }
})
