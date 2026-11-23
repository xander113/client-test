import { createHash } from 'node:crypto'
import { deflateSync } from 'node:zlib'
import { validateScene } from '../../shared/scene.mjs'

const width = 480
const height = 270
const supersample = 2
const frameWidth = width * supersample
const frameHeight = height * supersample

const normalize = vector => {
  const length = Math.hypot(...vector)
  return vector.map(component => component / length)
}
const cross = (a, b) => [
  a[1] * b[2] - a[2] * b[1],
  a[2] * b[0] - a[0] * b[2],
  a[0] * b[1] - a[1] * b[0]
]
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2]

const camera = normalize([0.61, 0.53, 0.73])
const right = normalize([camera[2], 0, -camera[0]])
const up = cross(camera, right)
const light = normalize([-0.3, 0.85, 0.45])

function boxGeometry() {
  const triangles = []
  for (let axis = 0; axis < 3; axis++) {
    for (const direction of [-1, 1]) {
      const normal = [0, 0, 0]
      normal[axis] = direction
      const corners = [[-0.5, -0.5], [0.5, -0.5], [0.5, 0.5], [-0.5, 0.5]]
        .map(([a, b]) => {
          const position = [0, 0, 0]
          position[axis] = direction * 0.5
          position[(axis + 1) % 3] = a
          position[(axis + 2) % 3] = b
          return { position, normal }
        })
      triangles.push([corners[0], corners[1], corners[2]], [corners[0], corners[2], corners[3]])
    }
  }
  return triangles
}

function sphereGeometry(segments, stacks) {
  const rows = Array.from({ length: stacks + 1 }, (_, row) => {
    const latitude = (row / stacks - 0.5) * Math.PI
    return Array.from({ length: segments }, (_, column) => {
      const angle = column * 2 * Math.PI / segments
      const normal = [
        Math.cos(latitude) * Math.cos(angle),
        Math.sin(latitude),
        Math.cos(latitude) * Math.sin(angle)
      ]
      return { position: normal.map(axis => axis * 0.5), normal }
    })
  })
  const triangles = []
  for (let y = 0; y < stacks; y++) {
    for (let x = 0; x < segments; x++) {
      const next = (x + 1) % segments
      const a = rows[y][x]
      const b = rows[y][next]
      const c = rows[y + 1][x]
      const d = rows[y + 1][next]
      if (y) triangles.push([a, b, c])
      if (y < stacks - 1) triangles.push([b, d, c])
    }
  }
  return triangles
}

function cylinderGeometry(segments) {
  const ring = Array.from({ length: segments }, (_, index) => {
    const angle = index * 2 * Math.PI / segments
    return [Math.cos(angle), 0, Math.sin(angle)]
  })
  const topNormal = [0, 1, 0]
  const bottomNormal = [0, -1, 0]
  const top = { position: [0, 0.5, 0], normal: topNormal }
  const bottom = { position: [0, -0.5, 0], normal: bottomNormal }
  const edge = (radial, y, normal) => ({ position: [radial[0] * 0.5, y, radial[2] * 0.5], normal })
  const triangles = []
  for (let index = 0; index < segments; index++) {
    const a = ring[index]
    const b = ring[(index + 1) % segments]
    const aTop = edge(a, 0.5, a)
    const bTop = edge(b, 0.5, b)
    const aBottom = edge(a, -0.5, a)
    const bBottom = edge(b, -0.5, b)
    triangles.push(
      [aTop, aBottom, bTop], [bTop, aBottom, bBottom],
      [top, edge(a, 0.5, topNormal), edge(b, 0.5, topNormal)],
      [bottom, edge(a, -0.5, bottomNormal), edge(b, -0.5, bottomNormal)]
    )
  }
  return triangles
}

const box = boxGeometry()
const meshes = {
  box: { standard: box, detailed: box },
  sphere: { standard: sphereGeometry(14, 8), detailed: sphereGeometry(24, 16) },
  cylinder: { standard: cylinderGeometry(14), detailed: cylinderGeometry(32) }
}

function fitCamera(scene) {
  const spawn = [scene.spawn.x, scene.spawn.y, scene.spawn.z]
  let minX = dot(spawn, right)
  let maxX = minX
  let minY = dot(spawn, up)
  let maxY = minY

  for (const { position, size } of scene.objects) {
    const x = dot(position, right)
    const y = dot(position, up)
    const marginX = (Math.abs(right[0]) * size[0] + Math.abs(right[2]) * size[2]) * 0.5
    const marginY = (Math.abs(up[0]) * size[0] + Math.abs(up[1]) * size[1] + Math.abs(up[2]) * size[2]) * 0.5
    minX = Math.min(minX, x - marginX)
    minY = Math.min(minY, y - marginY)
    maxX = Math.max(maxX, x + marginX)
    maxY = Math.max(maxY, y + marginY)
  }

  return {
    x: 0.5 * (minX + maxX),
    y: 0.5 * (minY + maxY),
    scale: Math.min(frameWidth * 0.88 / Math.max(8, maxX - minX),
      frameHeight * 0.82 / Math.max(6, maxY - minY))
  }
}

function makeFrame() {
  const color = new Uint8Array(frameWidth * frameHeight * 3)
  const depth = new Float32Array(frameWidth * frameHeight).fill(-Infinity)
  for (let y = 0; y < frameHeight; y++) {
    const blend = y / (frameHeight - 1)
    const r = Math.round(249 - 19 * blend)
    const g = Math.round(252 - 9 * blend)
    const b = Math.round(250 - 17 * blend)
    const row = y * frameWidth
    for (let x = 0; x < frameWidth; x++) {
      const offset = (row + x) * 3
      const border = Math.min(1, Math.abs(2 * x / frameWidth - 1))
      color[offset] = r - Math.round(3 * border)
      color[offset + 1] = g - Math.round(2 * border)
      color[offset + 2] = b - Math.round(3 * border)
    }
  }
  return { color, depth }
}

function drawTriangle(frame, a, b, c, rgb) {
  const dx1 = b.x - a.x
  const dy1 = b.y - a.y
  const dx2 = c.x - a.x
  const dy2 = c.y - a.y
  const area = dx1 * dy2 - dx2 * dy1
  if (Math.abs(area) < 0.001) return

  const minX = Math.max(0, Math.floor(Math.min(a.x, b.x, c.x)))
  const minY = Math.max(0, Math.floor(Math.min(a.y, b.y, c.y)))
  const maxX = Math.min(frameWidth - 1, Math.ceil(Math.max(a.x, b.x, c.x)))
  const maxY = Math.min(frameHeight - 1, Math.ceil(Math.max(a.y, b.y, c.y)))

  const bStep = dy2 / area
  const cStep = -dy1 / area
  const bDepth = b.depth - a.depth
  const cDepth = c.depth - a.depth
  const bShade = b.shade - a.shade
  const cShade = c.shade - a.shade

  for (let y = minY; y <= maxY; y++) {
    const yOffset = y + 0.5 - a.y
    const xOffset = minX + 0.5 - a.x
    let bWeight = (xOffset * dy2 - yOffset * dx2) / area
    let cWeight = (dx1 * yOffset - dy1 * xOffset) / area
    let index = y * frameWidth + minX

    for (let x = minX; x <= maxX; x++, index++, bWeight += bStep, cWeight += cStep) {
      if (bWeight < -1e-7 || cWeight < -1e-7 || bWeight + cWeight > 1.0000001) continue
      const depth = a.depth + bDepth * bWeight + cDepth * cWeight
      if (depth <= frame.depth[index]) continue

      const shade = a.shade + bShade * bWeight + cShade * cWeight
      const offset = index * 3
      frame.depth[index] = depth
      frame.color[offset] = Math.min(255, rgb[0] * shade + 6)
      frame.color[offset + 1] = Math.min(255, rgb[1] * shade + 8)
      frame.color[offset + 2] = Math.min(255, rgb[2] * shade + 7)
    }
  }
}

function drawObject(frame, projection, object, detailed) {
  const { size, position, kind, color } = object
  const geometry = meshes[kind][detailed ? 'detailed' : 'standard']
  const swatch = Number.parseInt(color.slice(1), 16)
  const rgb = [swatch >>> 16, (swatch >>> 8) & 255, swatch & 255]
  const transformed = new Map()

  for (const vertices of geometry) {
    const points = vertices.map(vertex => {
      const cached = transformed.get(vertex)
      if (cached) return cached

      const point = vertex.position.map((component, axis) => component * size[axis] + position[axis])
      const normal = normalize(vertex.normal.map((component, axis) => component / size[axis]))
      const screen = {
        x: frameWidth * 0.5 + (dot(point, right) - projection.x) * projection.scale,
        y: frameHeight * 0.5 - (dot(point, up) - projection.y) * projection.scale,
        depth: dot(point, camera),
        shade: 0.61 + 0.43 * Math.max(0, dot(normal, light)),
        facing: dot(normal, camera)
      }
      transformed.set(vertex, screen)
      return screen
    })

    if (points.every(point => point.facing <= 0)) continue
    drawTriangle(frame, points[0], points[1], points[2], rgb)
  }
}

const pngSignature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])
const crcTable = Uint32Array.from({ length: 256 }, (_, seed) => {
  let crc = seed
  for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0)
  return crc >>> 0
})

function chunk(name, data) {
  const buffer = Buffer.allocUnsafe(data.length + 12)
  buffer.writeUInt32BE(data.length, 0)
  buffer.write(name, 4, 4, 'ascii')
  data.copy(buffer, 8)
  let crc = 0xffffffff
  for (let offset = 4; offset < buffer.length - 4; offset++) {
    crc = (crc >>> 8) ^ crcTable[(crc ^ buffer[offset]) & 255]
  }
  buffer.writeUInt32BE((crc ^ 0xffffffff) >>> 0, buffer.length - 4)
  return buffer
}

function encodePng(frame) {
  const header = Buffer.alloc(13)
  header.writeUInt32BE(width, 0)
  header.writeUInt32BE(height, 4)
  header[8] = 8
  header[9] = 2

  const stride = width * 3 + 1
  const pixels = Buffer.allocUnsafe(stride * height)
  const channels = 3
  const step = frameWidth * channels

  for (let y = 0; y < height; y++) {
    const row = y * stride
    pixels[row] = 1 // PNG Sub filter
    const previous = [0, 0, 0]
    for (let x = 0; x < width; x++) {
      const src = ((y * supersample) * frameWidth + x * supersample) * channels
      const dst = row + x * channels + 1
      for (let channel = 0; channel < channels; channel++) {
        const i = src + channel
        const sample = (frame.color[i] + frame.color[i + channels] +
          frame.color[i + step] + frame.color[i + step + channels]) >>> 2
        pixels[dst + channel] = (sample - previous[channel]) & 255
        previous[channel] = sample
      }
    }
  }

  return Buffer.concat([
    pngSignature,
    chunk('IHDR', header),
    chunk('IDAT', deflateSync(pixels, { level: 4 })),
    chunk('IEND', Buffer.alloc(0))
  ])
}

const cache = new Map()
const maxCachedThumbnails = 64

export function renderThumbnail(input) {
  const scene = validateScene(input)
  const key = createHash('sha256').update(JSON.stringify(scene)).digest('hex')
  const cached = cache.get(key)
  if (cached) {
    cache.delete(key)
    cache.set(key, cached)
    return Buffer.from(cached)
  }

  const projection = fitCamera(scene)
  const frame = makeFrame()
  const sorted = [...scene.objects].sort((a, b) => dot(b.position, camera) - dot(a.position, camera))
  const detailed = sorted.length <= 24
  for (const object of sorted) drawObject(frame, projection, object, detailed)

  const png = encodePng(frame)
  cache.set(key, png)
  if (cache.size > maxCachedThumbnails) cache.delete(cache.keys().next().value)
  return Buffer.from(png)
}
