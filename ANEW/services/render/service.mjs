import { createHash, timingSafeEqual } from 'node:crypto'
import { createServer } from 'node:http'
import { isIP } from 'node:net'
import { Worker } from 'node:worker_threads'
import { MAX_SCENE_BYTES, validateScene } from '../../shared/scene.mjs'

class HttpError extends Error {
  constructor(status, message) {
    super(message)
    this.status = status
  }
}

const maxInFlight = 12
const bodyTimeout = 4000

function digest(value) {
  return createHash('sha256').update(value).digest()
}

function readBody(request) {
  if (Number(request.headers['content-length']) > MAX_SCENE_BYTES) {
    return Promise.reject(new HttpError(413, 'Scene payload is too large'))
  }

  return new Promise((resolve, reject) => {
    let length = 0
    const chunks = []
    const timer = setTimeout(() => fail(new HttpError(408, 'Scene payload timed out')), bodyTimeout)

    function cleanup() {
      clearTimeout(timer)
      request.off('data', onData)
      request.off('end', onEnd)
      request.off('error', onError)
      request.off('close', onClose)
    }
    function fail(error) {
      cleanup()
      request.pause()
      reject(error)
    }
    function onData(chunk) {
      length += chunk.length
      if (length > MAX_SCENE_BYTES) return fail(new HttpError(413, 'Scene payload is too large'))
      chunks.push(chunk)
    }
    function onEnd() {
      cleanup()
      resolve(Buffer.concat(chunks, length))
    }
    function onError() {
      fail(new HttpError(400, 'Scene payload could not be read'))
    }
    function onClose() {
      fail(new HttpError(400, 'Scene payload was interrupted'))
    }

    request.on('data', onData)
    request.once('end', onEnd)
    request.once('error', onError)
    request.once('close', onClose)
  })
}

function createRenderQueue(maxQueued, deadlineMs) {
  let active
  let worker
  let closed = false
  const pending = new Set()

  async function terminateWorker() {
    const previous = worker
    worker = undefined
    if (previous) await previous.terminate()
  }

  function finish(png, error) {
    const job = active
    active = undefined
    if (job) {
      clearTimeout(job.timer)
      if (error) job.reject(error)
      else job.resolve(png)
    }
    dispatch()
  }

  function startWorker() {
    const instance = new Worker(new URL('./render-worker.mjs', import.meta.url), {
      execArgv: [],
      resourceLimits: { maxOldGenerationSizeMb: 64, maxYoungGenerationSizeMb: 16 }
    })
    function handleFailure() {
      if (worker !== instance) return
      void terminateWorker().catch(() => {})
      finish(null, new HttpError(500, 'Thumbnail worker stopped unexpectedly'))
    }
    instance.on('message', png => {
      if (worker !== instance) return
      if (png instanceof Uint8Array) finish(Buffer.from(png.buffer, png.byteOffset, png.byteLength))
      else finish(null, new HttpError(500, 'Thumbnail rendering failed'))
    })
    instance.on('error', handleFailure)
    instance.on('exit', handleFailure)
    return instance
  }

  function dispatch() {
    if (active || closed || !pending.size) return
    active = pending.values().next().value
    pending.delete(active)
    try {
      worker ??= startWorker()
      worker.postMessage(active.scene)
    } catch {
      finish(null, new HttpError(500, 'Thumbnail worker could not start'))
    }
  }

  function render(scene) {
    if (closed) return Promise.reject(new HttpError(503, 'Thumbnail service is shutting down'))
    if (pending.size >= maxQueued) return Promise.reject(new HttpError(503, 'Thumbnail queue is full'))

    return new Promise((resolve, reject) => {
      const job = { scene, resolve, reject }
      job.timer = setTimeout(() => {
        const error = new HttpError(504, 'Thumbnail render timed out')
        if (active === job) {
          void terminateWorker().catch(() => {})
          finish(null, error)
        } else {
          pending.delete(job)
          reject(error)
        }
      }, deadlineMs)
      pending.add(job)
      dispatch()
    })
  }

  async function close() {
    closed = true
    const error = new HttpError(503, 'Thumbnail service is shutting down')
    for (const job of pending) {
      clearTimeout(job.timer)
      job.reject(error)
    }
    pending.clear()
    finish(null, error)
    await terminateWorker()
  }

  return { render, close }
}

function sendJson(response, status, data, extraHeaders = {}) {
  const body = JSON.stringify(data)
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...extraHeaders
  })
  response.end(body)
}

export async function startRenderService({
  host = '127.0.0.1',
  port = 0,
  token,
  maxQueued = 8,
  deadlineMs = 5000
} = {}) {
  const loopback = host === 'localhost' || host === '::1' || (isIP(host) === 4 && host.startsWith('127.'))
  if (!loopback && !token) throw new Error('POT_RENDER_TOKEN is required for a non-loopback listener')
  const expectedAuth = token ? digest(`Bearer ${token}`) : null
  const queue = createRenderQueue(maxQueued, deadlineMs)
  let inFlight = 0

  const server = createServer({
    headersTimeout: 5000,
    requestTimeout: 8000,
    keepAliveTimeout: 3000,
    maxHeaderSize: 8192
  }, async (request, response) => {
    if (request.url === '/healthz' && request.method === 'GET') {
      return sendJson(response, 200, { status: 'ok', service: 'PotRenderService' })
    }
    if (request.url !== '/v1/render') return sendJson(response, 404, { error: 'Route not found' })
    if (request.method !== 'POST') return sendJson(response, 405, { error: 'Use POST' }, { Allow: 'POST' })
    if (expectedAuth && !timingSafeEqual(digest(request.headers.authorization ?? ''), expectedAuth)) {
      return sendJson(response, 401, { error: 'Unauthorized' }, { 'WWW-Authenticate': 'Bearer', Connection: 'close' })
    }
    if (request.headers['content-type']?.split(';', 1)[0]?.trim().toLowerCase() !== 'application/json') {
      return sendJson(response, 415, { error: 'Send an application/json scene' }, { Connection: 'close' })
    }
    if (inFlight >= maxInFlight) {
      return sendJson(response, 503, { error: 'Thumbnail service is busy' }, { 'Retry-After': '1', Connection: 'close' })
    }

    inFlight++
    try {
      const input = await readBody(request)
      let scene
      try {
        scene = validateScene(JSON.parse(input.toString('utf8')))
      } catch {
        throw new HttpError(400, 'Invalid scene JSON')
      }
      const png = await queue.render(scene)
      if (response.destroyed) return
      response.writeHead(200, {
        'Content-Type': 'image/png',
        'Content-Length': png.length,
        'Cache-Control': 'private, max-age=60',
        'X-Content-Type-Options': 'nosniff'
      })
      response.end(png)
    } catch (error) {
      if (response.destroyed) return
      const status = error instanceof HttpError ? error.status : 500
      const headers = { Connection: 'close' }
      if (status === 503) headers['Retry-After'] = '1'
      sendJson(response, status, { error: error instanceof HttpError ? error.message : 'Thumbnail rendering failed' }, headers)
    } finally {
      inFlight--
    }
  })
  server.maxConnections = 64
  server.maxRequestsPerSocket = 100

  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject)
      server.listen(port, host, () => {
        server.off('error', reject)
        resolve()
      })
    })
  } catch (error) {
    await queue.close()
    throw error
  }

  const address = server.address()
  const endpoint = address.family === 'IPv6' ? `[${address.address}]` : address.address
  let closing
  return {
    url: `http://${endpoint}:${address.port}`,
    close() {
      closing ??= Promise.all([
        new Promise((resolve, reject) => {
          server.close(error => error ? reject(error) : resolve())
        }),
        queue.close()
      ]).then(() => undefined)
      return closing
    }
  }
}
