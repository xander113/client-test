import { createViewport } from '../common/viewport.js'

const desktop = window.pot
const byId = (id) => document.getElementById(id)
const library = byId('library')
const libraryContent = byId('library-content')
const game = byId('game')
const soloButton = byId('play-solo')
const joinButton = byId('join-online')
const canvasSlot = byId('canvas-slot')
const controls = byId('controls-dialog')
const playError = byId('play-error')
const search = byId('world-search')
const thumbnailRequests = new Map()
const cardPreviews = new IntersectionObserver((entries) => {
  for (const { target, isIntersecting } of entries) {
    if (!isIntersecting) continue
    cardPreviews.unobserve(target)
    void setThumbnail(target.dataset.world, target.firstElementChild)
  }
}, { rootMargin: '100px' })

let nextThumbnail = Promise.resolve()
let worlds = []
let selectedId = null
let networkMode = 'local'
let activeWorld = null
let launchTask = null
let refreshTask = null
let focusAfterPlay = soloButton

function setStatus(scope, state, text) {
  byId(`${scope}-status`).dataset.state = state
  byId(`${scope}-status-text`).textContent = text
}

function setLaunchStatus(text, error = false) {
  const message = byId('launch-status')
  message.textContent = text
  message.hidden = !text
  message.classList.toggle('error-text', error)
}

function setLaunchBusy(busy) {
  soloButton.disabled = busy
  joinButton.disabled = busy
}

function setGameView(playing) {
  library.hidden = playing
  game.hidden = !playing
  const navigation = byId('worlds-nav')
  navigation.classList.toggle('active', !playing)
  if (playing) navigation.removeAttribute('aria-current')
  else navigation.setAttribute('aria-current', 'page')
}

function currentWorld() {
  return worlds.find((world) => world.id === selectedId)
}

function requestThumbnail(worldId) {
  if (!thumbnailRequests.has(worldId)) {
    // A visible page can request many thumbnails at once. Keep the render queue bounded.
    const request = nextThumbnail.then(async () => {
      const data = await desktop.getThumbnail(worldId)
      return typeof data === 'string' && data.startsWith('data:image/png;base64,') ? data : null
    }).catch(() => null)

    if (thumbnailRequests.size >= 48) thumbnailRequests.delete(thumbnailRequests.keys().next().value)
    thumbnailRequests.set(worldId, request)
    nextThumbnail = request.then(() => {})
  }

  return thumbnailRequests.get(worldId)
}

async function setThumbnail(worldId, image) {
  if (image.dataset.world === worldId) return

  image.dataset.world = worldId
  image.hidden = true
  image.removeAttribute('src')
  const data = await requestThumbnail(worldId)
  if (image.dataset.world !== worldId || !data) return

  image.src = data
  image.hidden = false
}

function createIcon(name) {
  const namespace = 'http://www.w3.org/2000/svg'
  const icon = document.createElementNS(namespace, 'svg')
  icon.classList.add('icon')
  icon.setAttribute('aria-hidden', 'true')
  const link = document.createElementNS(namespace, 'use')
  link.setAttribute('href', `#icon-${name}`)
  icon.append(link)
  return icon
}

function selectWorld(id) {
  selectedId = id
  setLaunchStatus('')
  renderSelection()

  for (const card of byId('world-cards').children) {
    card.setAttribute('aria-pressed', String(card.dataset.id === id))
  }
}

function createCard(world) {
  const card = document.createElement('button')
  card.className = 'world-card'
  card.type = 'button'
  card.dataset.id = world.id
  card.setAttribute('aria-pressed', String(world.id === selectedId))
  card.addEventListener('click', () => selectWorld(world.id))

  const preview = document.createElement('span')
  preview.className = 'world-preview card-preview'
  preview.dataset.world = world.id
  const thumbnail = document.createElement('img')
  thumbnail.alt = ''
  thumbnail.decoding = 'async'
  thumbnail.hidden = true
  preview.append(thumbnail)

  const content = document.createElement('span')
  content.className = 'card-content'
  const label = document.createElement('span')
  label.className = 'card-title'
  label.textContent = world.name
  content.append(label, createIcon('chevron'))

  card.append(preview, content)
  return card
}

function renderCards() {
  const query = search.value.trim().toLocaleLowerCase()
  const filtered = worlds.filter((world) =>
    world.name.toLocaleLowerCase().includes(query) ||
    (world.description || '').toLocaleLowerCase().includes(query)
  )
  byId('empty-search').hidden = filtered.length !== 0
  const grid = byId('world-cards')
  cardPreviews.disconnect()
  grid.replaceChildren(...filtered.map(createCard))
  for (const preview of grid.querySelectorAll('.card-preview')) cardPreviews.observe(preview)
}

function renderSelection() {
  const world = currentWorld()
  libraryContent.hidden = !world
  if (!world) return

  byId('feature-title').textContent = world.name
  const description = byId('feature-description')
  description.textContent = world.description
  description.hidden = !world.description
  void setThumbnail(world.id, byId('feature-thumbnail'))
}

function setNetworkMode(mode) {
  networkMode = mode === 'hosted' ? 'hosted' : 'local'
  byId('join-label').textContent = networkMode === 'hosted' ? 'Join online' : 'Join local'
}

async function refreshLibrary() {
  if (refreshTask) return refreshTask

  refreshTask = (async () => {
    setStatus('library', 'working', 'Loading worlds')
    byId('library-error').hidden = true
    try {
      const result = await desktop.getWorlds()
      worlds = Array.isArray(result) ? result : []
      if (!currentWorld()) selectedId = worlds[0]?.id ?? null

      if (desktop.getNetworkMode) {
        try {
          setNetworkMode(await desktop.getNetworkMode())
        } catch {
          setNetworkMode('local')
        }
      }

      if (!worlds.length) {
        setStatus('library', 'neutral', 'No worlds')
        byId('library-error-text').textContent = 'Worlds appear here after they are published from Pot Studio.'
        byId('library-error').hidden = false
      } else {
        setStatus('library', 'ready', networkMode === 'hosted' ? 'Connected' : 'Local library')
      }

      byId('search-box').hidden = worlds.length < 5
      if (worlds.length < 5) search.value = ''
      thumbnailRequests.clear()
      byId('feature-thumbnail').removeAttribute('data-world')
      renderSelection()
      renderCards()
    } catch {
      setStatus('library', 'warning', 'Library unavailable')
      byId('library-error-text').textContent = 'The world library could not be loaded.'
      byId('library-error').hidden = false
    }
  })()

  try {
    await refreshTask
  } finally {
    refreshTask = null
  }
}

function updatePlayers(run, players) {
  const list = Array.isArray(players) ? players : []
  run.players = list
  run.viewport.setAvatars(list, run.selfId)

  const rosterKey = JSON.stringify(list.map(({ id, name, color }) => [id, name, color]))
  if (run.rosterKey === rosterKey) return
  run.rosterKey = rosterKey

  byId('player-count').textContent = String(list.length)
  byId('players-status').textContent = list.length ? '' : 'No players in this session.'
  byId('player-list').replaceChildren(...list.map((player) => {
    const item = document.createElement('li')
    const badge = document.createElement('span')
    badge.className = 'player-badge'
    if (/^#[0-9a-f]{6}$/i.test(player.color)) badge.style.backgroundColor = player.color
    const name = document.createElement('span')
    name.textContent = player.id === run.selfId ? `${player.name} (you)` : player.name
    item.append(badge, name)
    return item
  }))
}

function updatePlayback(run) {
  const ready = !controls.open && playError.hidden && (!run.online || run.connected)
  run.viewport.setPlaying(ready)
}

function continueSolo(run, message) {
  run.connected = false
  run.online = false
  run.unsubscribe?.()
  run.unsubscribe = null
  setStatus('game', 'warning', 'Playing solo')
  run.viewport.setAvatars([], null)
  byId('players-status').textContent = message
  byId('player-count').textContent = '0'
  byId('player-list').replaceChildren()
  updatePlayback(run)
}

function handleSession(run, event) {
  if (activeWorld !== run || !run.online || !event) return

  if (event.type === 'welcome') {
    run.selfId = event.id
    run.rosterKey = null
    if (run.players.length) updatePlayers(run, run.players)
  } else if (event.type === 'state') {
    updatePlayers(run, event.players)
  } else if (event.type === 'closed') {
    continueSolo(run, 'Session ended. You can keep exploring this world solo.')
  }
}

function stopWorld() {
  const run = activeWorld
  if (!run) return

  activeWorld = null
  run.unsubscribe?.()
  run.viewport.dispose()
  canvasSlot.replaceChildren()
  setGameView(false)

  if (run.sessionRequested) {
    Promise.resolve(desktop.leaveWorld()).catch(() => {})
  }

  focusAfterPlay.focus()
}

async function startWorld(id, online, focusTarget = soloButton) {
  if (launchTask || activeWorld || !id) return

  const task = {}
  launchTask = task
  focusAfterPlay = focusTarget
  setLaunchBusy(true)
  setLaunchStatus('Loading world…')
  let run

  try {
    const scene = await desktop.loadWorld(id)
    if (!scene) throw new Error('World not found')

    setGameView(true)
    byId('world-title').textContent = scene.name
    playError.hidden = true
    const canvas = document.createElement('canvas')
    canvas.className = 'world-canvas'
    canvas.tabIndex = 0
    canvas.setAttribute('aria-label', `${scene.name} play area`)
    canvasSlot.replaceChildren(canvas)

    run = {
      online,
      connected: false,
      sessionRequested: false,
      selfId: null,
      players: [],
      rosterKey: null,
      viewport: null,
      unsubscribe: null,
    }
    run.viewport = createViewport(canvas, {
      mode: 'client',
      onPose: (pose) => {
        if (activeWorld === run && run.connected) {
          Promise.resolve(desktop.move(pose)).catch(() => {})
        }
      },
      onError: () => {
        if (activeWorld !== run) return
        playError.textContent = 'The 3D view paused. Leave and reopen the world if it stays paused.'
        playError.hidden = false
        updatePlayback(run)
      },
      onRestore: () => {
        if (activeWorld !== run) return
        playError.hidden = true
        updatePlayback(run)
      },
    })
    activeWorld = run
    run.viewport.setScene(scene)
    setLaunchStatus('')
    canvas.focus()

    const panel = byId('players-panel')
    panel.hidden = !online
    byId('game-content').classList.toggle('with-players', online)
    if (!online) {
      setStatus('game', 'neutral', 'Solo')
      updatePlayback(run)
      return
    }

    setStatus('game', 'working', 'Joining session')
    byId('player-list').replaceChildren()
    byId('player-count').textContent = '0'
    byId('players-status').textContent = 'Connecting…'
    run.unsubscribe = desktop.onSession((event) => handleSession(run, event))
    run.sessionRequested = true

    try {
      await desktop.joinWorld(id)
      if (activeWorld !== run || !run.online) return
      run.connected = true
      setStatus('game', 'ready', networkMode === 'hosted' ? 'Online' : 'Local session')
      updatePlayback(run)
    } catch {
      if (activeWorld === run) {
        continueSolo(run, 'The session is unavailable. You can keep exploring this world solo.')
      }
    }
  } catch {
    const gameViewFailed = !game.hidden
    if (activeWorld) stopWorld()
    else {
      run?.viewport?.dispose()
      canvasSlot.replaceChildren()
      setGameView(false)
    }
    setLaunchStatus(
      gameViewFailed
        ? 'The 3D view could not start. Check graphics acceleration and try again.'
        : 'This world could not be opened. Refresh the library and try again.',
      true
    )
  } finally {
    if (launchTask === task) {
      launchTask = null
      setLaunchBusy(false)
    }
  }
}

byId('worlds-nav').addEventListener('click', () => {
  stopWorld()
  if (desktop) void refreshLibrary()
})
byId('retry').addEventListener('click', () => void refreshLibrary())
search.addEventListener('input', renderCards)
soloButton.addEventListener('click', () => void startWorld(selectedId, false, soloButton))
joinButton.addEventListener('click', () => void startWorld(selectedId, true, joinButton))
byId('leave-world').addEventListener('click', stopWorld)
byId('controls-nav').addEventListener('click', () => {
  activeWorld?.viewport.setPlaying(false)
  controls.showModal()
})
controls.addEventListener('close', () => {
  if (activeWorld) {
    updatePlayback(activeWorld)
    canvasSlot.firstElementChild?.focus()
  }
})
window.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && activeWorld && !controls.open) stopWorld()
})
window.addEventListener('pagehide', () => {
  cardPreviews.disconnect()
  activeWorld?.unsubscribe?.()
  activeWorld?.viewport.dispose()
})

async function start() {
  if (!desktop) {
    setStatus('library', 'warning', 'Desktop app required')
    byId('library-error-text').textContent = 'Open Pot Client from the desktop app to play.'
    byId('library-error').hidden = false
    byId('retry').hidden = true
    return
  }

  setNetworkMode('local')
  const loading = refreshLibrary()
  try {
    const worldId = await desktop.getLaunchWorld()
    if (worldId) await startWorld(worldId, false)
  } catch {
    setLaunchStatus('The Studio playtest could not be opened.', true)
  }
  await loading
}

void start()
