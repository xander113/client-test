import { createScene, validateScene } from '../../shared/scene.mjs'
import { createViewport } from '../common/viewport.js'

const axes = ['x', 'y', 'z']
const shapes = {
  box: { label: 'Box', size: [2, 2, 2], color: '#3eb36e' },
  sphere: { label: 'Sphere', size: [2, 2, 2], color: '#569ae9' },
  cylinder: { label: 'Cylinder', size: [2, 3, 2], color: '#dc9a4b' },
}
const historyLimit = 80
const desktop = window.pot
const byId = (id) => document.getElementById(id)
const objectList = byId('object-list')
const inspector = byId('inspector-body')
const canvas = byId('viewport')
const search = byId('object-search')
const modeButtons = [...document.querySelectorAll('[data-mode]')]
const snapInputs = ['snap', 'snap-distance', 'snap-angle', 'axes-space'].map(byId)
const dialog = byId('unsaved-dialog')
const actionButtons = new Map(Array.from(document.querySelectorAll('button[data-action]'), (button) => [button.dataset.action, button]))

const blank = createScene()
let scene = blank
let selection = null
let saved = scene
let history = [{ scene, selection }]
let historyIndex = 0
let busy = false
let viewport
let networkMode
let tool = 'select'
let axisSpace = 'world'
let playing = false
let dragging = false

function element(tag, className, value) {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (value !== undefined) node.textContent = value
  return node
}

function icon(name) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
  const use = document.createElementNS(svg.namespaceURI, 'use')
  svg.classList.add('icon')
  svg.setAttribute('aria-hidden', 'true')
  use.setAttribute('href', `#icon-${name}`)
  svg.append(use)
  return svg
}

function selectedObject() {
  return scene.objects.find((object) => object.id === selection)
}

function dirty() {
  return scene !== saved
}

function setStatus(message, kind = 'ready') {
  const status = byId('status-text')
  status.textContent = message
  status.title = message
  byId('status-dot').dataset.kind = kind
}

function showGraphicsError(error) {
  const notice = byId('graphics-error')
  notice.hidden = !error
  notice.textContent = error?.message || ''
  updateActions()
}

function updateActions() {
  const locked = busy || playing || dragging
  for (const action of ['open', 'save', 'save-as', 'publish']) {
    actionButtons.get(action).disabled = !desktop || locked
  }
  actionButtons.get('playtest').disabled = busy || dragging || !viewport || !byId('graphics-error').hidden
  actionButtons.get('new').disabled = locked
  actionButtons.get('frame').disabled = locked || !viewport || !byId('graphics-error').hidden
  actionButtons.get('undo').disabled = locked || historyIndex === 0
  actionButtons.get('redo').disabled = locked || historyIndex === history.length - 1
  actionButtons.get('duplicate').disabled = locked || !selection
  actionButtons.get('delete').disabled = locked || !selection
  for (const kind of Object.keys(shapes)) actionButtons.get(`add-${kind}`).disabled = locked
  for (const control of [...modeButtons, ...snapInputs, byId('camera-view')]) control.disabled = locked
  byId('axes-space').disabled = locked || tool === 'scale'
  byId('dirty-indicator').hidden = !dirty()
  byId('editor-dock').inert = playing || busy
}

function updateTool() {
  const [enabled, distance, angle, space] = snapInputs
  for (const button of modeButtons) button.setAttribute('aria-pressed', String(button.dataset.mode === tool))
  space.value = tool === 'scale' ? 'local' : axisSpace
  viewport?.setTool(tool, space.value, enabled.checked && distance.validity.valid && angle.validity.valid,
    distance.valueAsNumber, angle.valueAsNumber)
}

function selectTool(mode) {
  if (busy || playing || dragging) return
  tool = mode
  updateTool()
  updateActions()
  if (mode !== 'select' && !selection) {
    setStatus('Select a part in the viewport or Outliner.')
  } else {
    setStatus({ select: 'Select parts', translate: 'Drag a handle to move', rotate: 'Drag a ring to rotate', scale: 'Drag a handle to scale' }[mode])
  }
}

function updateSelection() {
  byId('select-world').setAttribute('aria-pressed', String(!selection))
  for (const button of objectList.querySelectorAll('button')) {
    button.setAttribute('aria-pressed', String(button.dataset.objectId === selection))
  }
  viewport?.setSelected(selection)
  updateActions()
}

function select(id) {
  if (playing || dragging || selection === id) return
  selection = id
  history[historyIndex].selection = id
  renderInspector()
  updateSelection()
  revealSelection()
}

function revealSelection() {
  if (!selection) return
  byId('object-group').open = true
  objectList.querySelector('[aria-pressed="true"]')?.scrollIntoView({ block: 'nearest' })
}

function renderOutliner() {
  byId('world-title').textContent = scene.name
  byId('document-label').title = scene.name
  byId('outliner-world').textContent = scene.name
  const query = search.value.trim().toLocaleLowerCase()
  const parts = scene.objects.filter((part) => !query || part.name.toLocaleLowerCase().includes(query))
  byId('object-count').textContent = query ? `${parts.length} / ${scene.objects.length}` : scene.objects.length
  const empty = byId('empty-objects')
  empty.hidden = parts.length > 0
  empty.textContent = query ? 'No matching parts.' : 'Add a part from the toolbar.'
  const scroller = objectList.closest('.outliner-scroll')
  const scrollTop = scroller.scrollTop
  const focused = document.activeElement?.dataset.objectId

  const rows = parts.map((object) => {
    const row = element('li')
    const button = element('button', 'outline-row')
    button.type = 'button'
    button.title = object.name
    button.dataset.objectId = object.id
    const swatch = element('span', 'outline-swatch')
    swatch.setAttribute('aria-hidden', 'true')
    swatch.style.backgroundColor = object.color
    button.append(icon(object.kind), element('span', 'outline-name', object.name), swatch)
    row.append(button)
    return row
  })
  objectList.replaceChildren(...rows)
  scroller.scrollTop = scrollTop
  if (focused) objectList.querySelector(`[data-object-id="${focused}"]`)?.focus({ preventScroll: true })
}

function section(title, ...fields) {
  const container = element('section', 'property-section')
  const contents = element('div', 'property-fields')
  contents.append(...fields)
  container.append(element('h3', '', title), contents)
  return container
}

function field(label, property, value, type = 'text', options = {}) {
  const wrapper = element('label', 'field')
  const caption = element('span', 'field-label', label)
  const input = element(type === 'textarea' ? 'textarea' : 'input')
  if (type !== 'textarea') input.type = type
  input.value = value
  input.dataset.property = property
  Object.assign(input, options)
  wrapper.append(caption, input)
  return wrapper
}

function vector(label, property, values) {
  const wrapper = element('div')
  const fields = element('div', 'vector-fields')
  const caption = element('span', 'vector-label', label)
  for (const [index, axis] of axes.entries()) {
    const limits = {
      size: [0.1, 128], rotation: [-180, 180],
    }[property] ?? [axis === 'y' ? -40 : -250, 250]
    const value = Array.isArray(values) ? values[index] : values[axis]
    const axisField = field(axis.toUpperCase(), property, value, 'number', {
      min: limits[0], max: limits[1], step: 'any', required: true,
    })
    const input = axisField.querySelector('input')
    input.dataset.axis = axis
    input.setAttribute('aria-label', `${label} ${axis.toUpperCase()}`)
    fields.append(axisField)
  }
  wrapper.append(caption, fields)
  return wrapper
}

function solidField(value) {
  const wrapper = element('label', 'checkbox-field')
  const input = element('input')
  input.type = 'checkbox'
  input.dataset.property = 'solid'
  input.checked = value
  wrapper.append(input, element('span', '', 'Solid collision'))
  return wrapper
}

function renderInspector() {
  const object = selectedObject()
  byId('inspector-kind').textContent = object ? shapes[object.kind].label : 'World'
  const name = field('Name', 'name', (object || scene).name, 'text', { maxLength: 80, required: true })
  if (object) {
    inspector.replaceChildren(
      section('Object', name),
      section('Transform',
        vector('Position', 'position', object.position),
        vector('Rotation (°)', 'rotation', object.rotation),
        vector('Size', 'size', object.size)),
      section('Appearance', field('Color', 'color', object.color, 'color'), solidField(object.solid)),
    )
    return
  }
  inspector.replaceChildren(
    section('Details', name, field('Description', 'description', scene.description, 'textarea', { maxLength: 400, rows: 2 })),
    section('Player spawn', vector('Position', 'spawn', scene.spawn)),
  )
}

function renderScene({ keepInspector = false } = {}) {
  renderOutliner()
  if (!keepInspector) renderInspector()
  viewport?.setScene(scene)
  updateSelection()
}

function applyEdit(edit, nextSelection = selection, keepInspector = false) {
  const draft = structuredClone(scene)
  edit(draft)
  const next = validateScene(draft)
  if (JSON.stringify(scene) === JSON.stringify(next)) return
  scene = next
  selection = nextSelection
  history.splice(historyIndex + 1)
  history.push({ scene, selection })
  if (history.length > historyLimit) history.shift()
  historyIndex = history.length - 1
  renderScene({ keepInspector })
}

function changeHistory(delta) {
  const target = historyIndex + delta
  if (target < 0 || target >= history.length) return
  historyIndex = target
  const state = history[historyIndex]
  scene = state.scene
  selection = state.selection
  renderScene()
  setStatus(delta < 0 ? 'Undid the last edit' : 'Redid the last edit')
}

function setProject(newScene) {
  scene = validateScene(newScene)
  selection = null
  saved = scene
  history = [{ scene, selection }]
  historyIndex = 0
  search.value = ''
  byId('object-group').open = true
  renderScene()
  viewport?.focus()
}

function readProperty(object, property, axis) {
  const value = object[property]
  if (!axis) return value
  return value[Array.isArray(value) ? axes.indexOf(axis) : axis]
}

function changeProperty(input) {
  const { property, axis } = input.dataset
  const current = readProperty(selectedObject() || scene, property, axis)
  const checkbox = input.type === 'checkbox'
  try {
    if (!input.validity.valid) {
      input.reportValidity()
      throw new Error(`Check the ${axis ? `${property} ${axis.toUpperCase()}` : property} value.`)
    }
    let value = input.value
    if (checkbox) value = input.checked
    else if (axis) value = input.valueAsNumber
    else if (property === 'description') value = value.replace(/\n/gu, ' ')
    applyEdit((draft) => {
      const object = selection ? draft.objects.find((item) => item.id === selection) : draft
      if (!axis) {
        object[property] = value
        return
      }
      const target = object[property]
      target[Array.isArray(target) ? axes.indexOf(axis) : axis] = value
    }, selection, true)
    if (!checkbox) input.value = readProperty(selectedObject() || scene, property, axis)
    setStatus('Project updated')
  } catch (error) {
    if (checkbox) input.checked = current
    else input.value = current
    setStatus(error.message, 'error')
  }
}

function nextName(label) {
  const names = new Set(scene.objects.map((object) => object.name))
  let number = 2
  let name = label
  while (names.has(name)) {
    const suffix = ` ${number++}`
    name = label.slice(0, 80 - suffix.length) + suffix
  }
  return name
}

function beside(object, size) {
  const [x, y, z] = object.position
  const spacing = (object.size[0] + size[0]) / 2 + 0.5
  const nextX = x + spacing > 250 ? x - spacing : x + spacing
  return [nextX, Math.max(-40, Math.min(250, y + (size[1] - object.size[1]) / 2)), z]
}

function add(kind) {
  const shape = shapes[kind]
  const id = crypto.randomUUID()
  const { x, y, z } = scene.spawn
  const selected = selectedObject()
  const position = selected && selected.size[0] <= 12
    ? beside(selected, shape.size)
    : [x > 247.5 ? x - 2.5 : x + 2.5, Math.min(250, y + shape.size[1] / 2), z]
  applyEdit((draft) => draft.objects.push({
    id, name: nextName(shape.label), kind, position, rotation: [0, 0, 0], size: shape.size, color: shape.color, solid: true,
  }), id)
  revealSelection()
  setStatus(`Added a ${kind}`)
}

function duplicate() {
  const object = selectedObject()
  if (!object) return
  const id = crypto.randomUUID()
  const name = nextName(`${object.name.slice(0, 75)} copy`)
  applyEdit((draft) => draft.objects.push({ ...object, id, name, position: beside(object, object.size) }), id)
  revealSelection()
  setStatus(`Duplicated ${object.name}`)
}

function deleteSelected() {
  const object = selectedObject()
  if (!object) return
  applyEdit((draft) => {
    draft.objects = draft.objects.filter((item) => item.id !== object.id)
  }, null)
  setStatus(`Deleted ${object.name}`)
}

async function saveProject(saveAs = false) {
  const snapshot = scene
  if (!await desktop.saveProject(snapshot, saveAs)) {
    setStatus('Save canceled')
    return false
  }
  saved = snapshot
  updateActions()
  setStatus(`Saved ${snapshot.name}`)
  return true
}

async function canDiscardChanges() {
  if (!dirty()) return true
  const response = new Promise((resolve) => {
    dialog.addEventListener('close', () => resolve(dialog.returnValue), { once: true })
  })
  dialog.returnValue = 'cancel'
  if (!desktop) dialog.querySelector('[value="save"]').disabled = true
  dialog.showModal()
  const answer = await response
  if (answer === 'discard') return true
  if (answer === 'save') return saveProject()
  return false
}

async function newProject() {
  if (!await canDiscardChanges()) {
    setStatus('New project canceled')
    return
  }
  setProject(createScene())
  setStatus('New project')
}

async function openProject() {
  if (!await canDiscardChanges()) {
    setStatus('Open canceled')
    return
  }
  const project = await desktop.openProject()
  if (!project) {
    setStatus('Open canceled')
    return
  }
  setProject(project)
  setStatus(`Opened ${scene.name}`)
}

function playtest() {
  playing = !playing
  viewport.playtest(playing)
  document.body.classList.toggle('playtesting', playing)
  byId('playtest-label').textContent = playing ? 'Stop' : 'Playtest'
  actionButtons.get('playtest').querySelector('use').setAttribute('href', playing ? '#icon-stop' : '#icon-play')
  actionButtons.get('playtest').title = playing ? 'Stop playtest (F5 or Esc)' : 'Playtest in this view (F5)'
  byId('edit-help').hidden = playing
  byId('play-help').hidden = !playing
  canvas.setAttribute('aria-label', playing ? 'Playtest viewport' : 'Editable 3D scene')
  canvas.focus()
  setStatus(playing ? 'Playtesting from the current spawn' : 'Returned to editing')
  updateActions()
}

function previewTransform(transform) {
  for (const property of ['position', 'rotation', 'size']) {
    for (const input of inspector.querySelectorAll(`input[data-property="${property}"]`)) {
      input.value = transform[property][axes.indexOf(input.dataset.axis)]
    }
  }
}

function commitTransform(id, transform) {
  if (!id || selection !== id) return
  try {
    applyEdit((draft) => Object.assign(draft.objects.find((part) => part.id === id), transform), id, true)
    previewTransform(selectedObject())
    setStatus({ translate: 'Part moved', rotate: 'Part rotated', scale: 'Part resized' }[tool] || 'Part updated')
  } catch (error) {
    viewport.setScene(scene)
    previewTransform(selectedObject())
    setStatus(error.message, 'error')
  }
}

async function publish() {
  const snapshot = scene
  await desktop.publishWorld(snapshot)
  setStatus(networkMode === 'local' ? `Published ${snapshot.name} to the local library` : `Published ${snapshot.name}`)
}

async function perform(work, progress) {
  if (busy) return
  busy = true
  updateActions()
  setStatus(progress, 'busy')
  try {
    await work()
  } catch (error) {
    setStatus(error.message, 'error')
  } finally {
    busy = false
    updateActions()
  }
}

const actions = {
  new: () => perform(newProject, 'Creating project…'),
  open: () => perform(openProject, 'Opening project…'),
  save: () => perform(saveProject, 'Saving project…'),
  'save-as': () => perform(() => saveProject(true), 'Saving project…'),
  undo: () => changeHistory(-1),
  redo: () => changeHistory(1),
  'add-box': () => add('box'),
  'add-sphere': () => add('sphere'),
  'add-cylinder': () => add('cylinder'),
  delete: deleteSelected,
  duplicate,
  frame: () => viewport?.focus(selection || undefined),
  playtest,
  publish: () => perform(publish, 'Publishing…'),
}

function activate(action) {
  if (actionButtons.get(action)?.disabled) return
  try {
    actions[action]()
  } catch (error) {
    setStatus(error.message, 'error')
  }
}

for (const [action, button] of actionButtons) {
  button.addEventListener('click', () => activate(action))
}
for (const button of modeButtons) button.addEventListener('click', () => selectTool(button.dataset.mode))
for (const input of snapInputs) input.addEventListener('change', () => {
  if (!input.validity.valid) { input.reportValidity(); return }
  if (input.id === 'axes-space') axisSpace = input.value
  updateTool()
})
byId('camera-view').addEventListener('change', (event) => {
  viewport?.focus(selection, event.target.value)
  event.target.value = ''
})
search.addEventListener('input', () => {
  if (search.value) byId('object-group').open = true
  renderOutliner()
  updateSelection()
})
byId('select-world').addEventListener('click', () => select(null))
objectList.addEventListener('click', (event) => {
  const row = event.target.closest('button[data-object-id]')
  if (row) select(row.dataset.objectId)
})
inspector.addEventListener('change', (event) => {
  if (event.target.dataset.property) changeProperty(event.target)
})
window.addEventListener('beforeunload', (event) => {
  if (!dirty()) return
  event.preventDefault()
  event.returnValue = false
})
window.addEventListener('keydown', (event) => {
  if (event.defaultPrevented || dialog.open) return
  const key = event.key.toLowerCase()
  const field = event.target instanceof HTMLElement && (event.target.matches('input, textarea, select') || event.target.isContentEditable)
  if (key === 'escape' && viewport?.cancelTransform()) {
    event.preventDefault()
    setStatus('Transform canceled')
    return
  }
  if (key === 'f5' || (playing && key === 'escape')) {
    event.preventDefault()
    if (field) event.target.blur()
    activate('playtest')
    return
  }
  if (playing) return
  let action
  if (event.ctrlKey || event.metaKey) {
    if (key === 's') action = event.shiftKey ? 'save-as' : 'save'
    else if (key === 'o') action = 'open'
    else if (!field && key === 'z') action = event.shiftKey ? 'redo' : 'undo'
    else if (!field && key === 'y') action = 'redo'
    else if (!field && key === 'd') action = 'duplicate'
  } else if (!field && !event.altKey) {
    if (key === 'f') action = 'frame'
    else if (key === 'delete' || key === 'backspace') action = 'delete'
    else if (['q', 'w', 'e', 'r'].includes(key)) {
      event.preventDefault()
      selectTool({ q: 'select', w: 'translate', e: 'rotate', r: 'scale' }[key])
      canvas.focus({ preventScroll: true })
      return
    }
  }
  if (!action) return
  event.preventDefault()
  if (field) event.target.blur()
  activate(action)
})

try {
  viewport = createViewport(canvas, {
    mode: 'studio',
    onSelect: select,
    onTransform: commitTransform,
    onPreview: previewTransform,
    onDragging(active) { dragging = active; updateActions() },
    onError: showGraphicsError,
    onRestore: () => showGraphicsError(null),
  })
} catch (error) {
  showGraphicsError(error)
}
renderScene()
updateTool()

const divider = byId('dock-divider')
let dockWidth = 300
function resizeDock(width) {
  dockWidth = Math.max(245, Math.min(460, Math.round(width)))
  document.querySelector('.workspace').style.setProperty('--dock-width', `${dockWidth}px`)
  divider.setAttribute('aria-valuenow', String(dockWidth))
}
divider.addEventListener('pointerdown', (event) => {
  if (playing || event.button !== 0) return
  divider.setPointerCapture(event.pointerId)
  divider.dataset.resizing = ''
})
divider.addEventListener('pointermove', (event) => {
  if (divider.hasPointerCapture(event.pointerId)) resizeDock(document.documentElement.clientWidth - event.clientX - 4)
})
divider.addEventListener('lostpointercapture', () => { delete divider.dataset.resizing })
divider.addEventListener('keydown', (event) => {
  if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return
  event.preventDefault()
  resizeDock(dockWidth + (event.key === 'ArrowLeft' ? 16 : -16))
})

if (desktop?.getSampleProject) {
  desktop.getSampleProject().then((sample) => {
    if (scene === blank && !busy) setProject({ ...sample, id: blank.id, name: 'Terrace Workshop' })
  }).catch(() => {})
}
if (desktop?.getNetworkMode) {
  desktop.getNetworkMode().then((mode) => {
    networkMode = mode
    byId('network-status').textContent = mode === 'local' ? 'Local library' : 'Hosted library'
  }).catch(() => {})
}
