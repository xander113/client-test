import { startRenderService } from './service.mjs'

const port = Number(process.env.POT_RENDER_PORT ?? 4812)
if (!Number.isInteger(port) || port < 0 || port > 65535) {
  throw new Error('POT_RENDER_PORT must be an integer between 0 and 65535')
}

const service = await startRenderService({
  host: process.env.POT_RENDER_HOST,
  port,
  token: process.env.POT_RENDER_TOKEN
})

console.log(`PotRenderService listening at ${service.url}`)

async function close() {
  try {
    await service.close()
  } catch (error) {
    console.error(error.message)
    process.exitCode = 1
  }
}
process.once('SIGINT', close)
process.once('SIGTERM', close)
