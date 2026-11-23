import { createScene, starterWorlds, validateScene } from '../../shared/scene.mjs'
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
const dialog = byId('unsaved-dialog')
const actionButtons = new Map(Array.from(document.querySelectorAll('button[data-action]'), (button) => [button.dataset.action, button]))

const blank = createScene()
const sample = starterWorlds[0]
let scene = sample ? validateScene({ ...sample, id: blank.id }) : blank
let selection = null
let saved = JSON.stringify(scene)
let history = [{ scene, selection }]
let historyIndex = 0
let busy = false
let viewport
let networkMode

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
  return JSON.stringify(scene) !== saved
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
  for (const action of ['open', 'save', 'save-as', 'playtest', 'publish']) {
    actionButtons.get(action).disabled = !desktop || busy
  }
  actionButtons.get('new').disabled = busy
  actionButtons.get('frame').disabled = !viewport || !byId('graphics-error').hidden
  actionButtons.get('undo').disabled = busy || historyIndex === 0
  actionButtons.get('redo').disabled = busy || historyIndex === history.length - 1
  actionButtons.get('duplicate').disabled = busy || !selection
  actionButtons.get('delete').disabled = busy || !selection
  for (const kind of Object.keys(shapes)) {
    actionButtons.get(`add-${kind}`).disabled = busy
  }
  byId('dirty-indicator').hidden = !dirty()
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
  if (selection === id) return
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
  byId('object-count').textContent = scene.objects.length
  byId('empty-objects').hidden = scene.objects.length > 0

  const rows = scene.objects.map((object) => {
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

function vector(label, property, values, isSize = false) {
  const wrapper = element('div')
  const fields = element('div', 'vector-fields')
  const caption = element('span', 'vector-label', label)
  for (const [index, axis] of axes.entries()) {
    const limits = isSize ? [0.1, 128] : [axis === 'y' ? -40 : -250, 250]
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
      section('Transform', vector('Position', 'position', object.position), vector('Size', 'size', object.size, true)),
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
  saved = JSON.stringify(scene)
  history = [{ scene, selection }]
  historyIndex = 0
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
    id, name: nextName(shape.label), kind, position, size: shape.size, color: shape.color, solid: true,
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
  saved = JSON.stringify(snapshot)
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

async function playtest() {
  await desktop.playtest(scene)
  setStatus('Playtest opened in Pot Client')
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
  playtest: () => perform(playtest, 'Opening playtest…'),
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
  const field = event.target instanceof HTMLElement && (event.target.matches('input, textarea') || event.target.isContentEditable)
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
  }
  if (!action) return
  event.preventDefault()
  if (field) event.target.blur()
  activate(action)
})

try {
  viewport = createViewport(byId('viewport'), {
    mode: 'studio',
    onSelect: select,
    onError: showGraphicsError,
    onRestore: () => showGraphicsError(null),
  })
} catch (error) {
  showGraphicsError(error)
}
renderScene()

if (desktop?.getNetworkMode) {
  desktop.getNetworkMode().then((mode) => {
    networkMode = mode
    byId('network-status').textContent = mode === 'local' ? 'Local library' : 'Hosted library'
  }).catch(() => {})
}
