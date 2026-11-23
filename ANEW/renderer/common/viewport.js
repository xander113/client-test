import {
  ACESFilmicToneMapping, Box3, BoxGeometry, CapsuleGeometry, Color, EdgesGeometry,
  CylinderGeometry, DirectionalLight, FogExp2, GridHelper, Group, HemisphereLight, LineBasicMaterial, LineSegments, MOUSE,
  Mesh, MeshStandardMaterial, PCFShadowMap, PerspectiveCamera, Ray, Raycaster,
  Scene, SphereGeometry, Vector2, Vector3, WebGLRenderer,
} from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { TransformControls } from 'three/addons/controls/TransformControls.js';

const AVATAR_RADIUS = 0.3;
const AVATAR_HEIGHT = 1.65;
const STEP_HEIGHT = 0.25;
const WALK_SPEED = 6.5;
const JUMP_SPEED = 8.2;
const GRAVITY = 22;
const EPSILON = 0.001;
const MOVE_KEYS = new Set([
  'KeyW', 'KeyA', 'KeyS', 'KeyD', 'ArrowUp', 'ArrowLeft', 'ArrowDown', 'ArrowRight', 'Space',
]);

function avatar(geometry, color) {
  const bodyMaterial = new MeshStandardMaterial({ color, roughness: 0.62 });
  const visorMaterial = new MeshStandardMaterial({ color: '#284658', roughness: 0.3 });
  const group = new Group();
  const body = new Mesh(geometry.torso, bodyMaterial);
  body.position.y = 0.56;
  body.castShadow = true;
  const head = new Mesh(geometry.sphere, bodyMaterial);
  head.scale.setScalar(0.6);
  head.position.y = 1.23;
  head.castShadow = true;
  const visor = new Mesh(geometry.sphere, visorMaterial);
  visor.scale.set(0.54, 0.28, 0.26);
  visor.position.set(0, 1.29, -0.23);
  group.add(body, head, visor);
  return { group, bodyMaterial, visorMaterial, destination: new Vector3(), yaw: 0 };
}

function disposeAvatar(data) {
  data.group.removeFromParent();
  data.bodyMaterial.dispose();
  data.visorMaterial.dispose();
}

function overlapsFootprint(box, x, z) {
  return x + AVATAR_RADIUS > box.min.x && x - AVATAR_RADIUS < box.max.x &&
    z + AVATAR_RADIUS > box.min.z && z - AVATAR_RADIUS < box.max.z;
}

function overlapsHeight(box, feet) {
  return feet + AVATAR_HEIGHT > box.min.y + EPSILON && feet < box.max.y - EPSILON;
}

/**
 * Draws a validated Pot scene and supports editing or play with the same parts.
 * Spawn and session positions denote the player's feet. Parts use center positions.
 */
export function createViewport(canvas, {
  mode = 'studio', onSelect, onTransform, onPreview, onDragging, onInput, onError, onRestore,
} = {}) {
  const hasEditor = mode === 'studio';
  let isStudio = hasEditor;
  let renderer;
  try {
    renderer = new WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
  } catch (error) {
    throw new Error('A WebGL2-capable graphics driver is required to open the 3D viewport.', { cause: error });
  }

  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.75));
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.autoUpdate = false;
  renderer.shadowMap.type = PCFShadowMap;
  renderer.toneMapping = ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.14;

  const scene = new Scene();
  scene.background = new Color(isStudio ? '#eaf2f6' : '#dceef8');
  scene.fog = new FogExp2(scene.background, 0.007);
  const world = new Group();
  const people = new Group();
  scene.add(world, people);

  const hemisphere = new HemisphereLight('#eef7ff', '#b8c8bd', 2.3);
  const sun = new DirectionalLight('#fff3d9', 2.35);
  sun.castShadow = true;
  sun.shadow.mapSize.set(1024, 1024);
  sun.shadow.normalBias = 0.05;
  sun.shadow.bias = -0.0002;
  sun.shadow.camera.near = 1;
  sun.shadow.camera.far = 195;
  scene.add(hemisphere, sun, sun.target);

  const playCamera = new PerspectiveCamera(62, 1, 0.095, 520);
  const editCamera = hasEditor ? new PerspectiveCamera(45, 1, 0.095, 560) : null;
  let camera = editCamera ?? playCamera;
  // Register the gizmo first so grabbing a handle cannot also begin a camera orbit.
  const gizmo = editCamera ? new TransformControls(editCamera, canvas) : null;
  const orbit = editCamera ? new OrbitControls(editCamera, canvas) : null;
  if (orbit) {
    orbit.enableDamping = true;
    orbit.dampingFactor = 0.15;
    orbit.enablePan = true;
    orbit.mouseButtons = { LEFT: MOUSE.ROTATE, MIDDLE: MOUSE.PAN, RIGHT: null };
    orbit.maxDistance = 380;
    orbit.maxPolarAngle = Math.PI - 0.015;
    orbit.minDistance = 1;
  }
  if (gizmo) {
    gizmo.setSize(0.78);
    gizmo.detach();
    scene.add(gizmo.getHelper());
  }

  const grid = hasEditor ? new GridHelper(240, 240, '#7c948a', '#a7b8ac') : null;
  if (grid) {
    grid.position.y = 0.012;
    grid.material.transparent = true;
    grid.material.opacity = 0.22;
    grid.material.depthWrite = false;
    scene.add(grid);
  }

  const geometries = {
    box: new BoxGeometry(),
    sphere: new SphereGeometry(0.5, 20, 14),
    cylinder: new CylinderGeometry(0.5, 0.5, 1, 24),
    torso: new CapsuleGeometry(0.31, 0.47, 6, 14),
  };
  const outline = hasEditor ? new LineSegments(
    new EdgesGeometry(geometries.box),
    new LineBasicMaterial({ color: '#078b2a', transparent: true, opacity: 0.9 }),
  ) : null;
  if (outline) {
    outline.visible = false;
    outline.material.depthTest = false;
    outline.renderOrder = 10;
    scene.add(outline);
  }

  const parts = new Map();
  const colliderBounds = [];
  const remoteAvatars = new Map();
  const bounds = new Box3();
  const partSize = new Vector3();
  const spawn = new Vector3(0, 1, 0);
  const position = new Vector3();
  const self = avatar(geometries, '#09b734');
  self.group.visible = !hasEditor;
  people.add(self.group);
  const keys = new Set();
  const raycaster = new Raycaster();
  const pointer = new Vector2();
  const cameraRay = new Ray();
  const cameraTarget = new Vector3();
  const cameraOffset = new Vector3();
  const intersection = new Vector3();
  const authoritative = new Vector3();
  const flyDirection = new Vector3();
  const flyRight = new Vector3();
  const flyMotion = new Vector3();
  const worldUp = new Vector3(0, 1, 0);
  const center = new Vector3();
  const orbitOffset = new Vector3(1, 0.71, 1).normalize();
  const listeners = new AbortController();
  let sceneId = null;
  let pointerDown = null;
  let selected = null;
  let playing = false;
  let networked = false;
  let hasAuthority = false;
  let jumpSequence = 0;
  let lastInputKey = '';
  let lastInputTime = 0;
  let focusMotion;
  let flyPointer = null;
  let flyDistance = 8;
  let flyYaw = 0;
  let flyPitch = 0;
  let visible = true;
  let tool = 'select';
  let canceled = false;
  let jumped = false;
  let grounded = false;
  let frame = 0;
  let lastFrame = 0;
  let fallSpeed = 0;
  let yaw = 0;
  let heading = yaw;
  let pitch = 0.34;
  let zoom = 8.5;
  let contextLost = false;
  let disposed = false;
  let redraw = true;

  function refreshOutline() {
    if (!outline) return;
    const part = parts.get(selected);
    outline.visible = isStudio && Boolean(part);
    if (part && isStudio) {
      outline.position.copy(part.mesh.position);
      outline.quaternion.copy(part.mesh.quaternion);
      outline.scale.copy(part.mesh.scale).multiplyScalar(1.001);
    }
    if (!gizmo.dragging) {
      if (part && isStudio && tool !== 'select' && flyPointer === null) {
        if (gizmo.object !== part.mesh) gizmo.attach(part.mesh);
      } else if (gizmo.object) {
        gizmo.detach();
      }
    }
    redraw = true;
  }

  function resetPlayer() {
    position.copy(spawn);
    for (const collider of colliderBounds) {
      if (overlapsFootprint(collider, position.x, position.z) && overlapsHeight(collider, position.y)) {
        position.y = Math.max(position.y, collider.max.y);
      }
    }
    fallSpeed = 0;
    grounded = false;
    renderer.shadowMap.needsUpdate = true;
    redraw = true;
  }

  function frameOrbit(id, view, instant = false) {
    if (!orbit || !isStudio) return;
    const target = parts.get(id)?.box || bounds;
    if (target.isEmpty()) {
      center.copy(spawn);
      partSize.set(10, 6, 10);
    } else {
      target.getCenter(center);
      target.getSize(partSize);
    }
    const radius = Math.max(1, partSize.length() * 0.5);
    const visibleAngle = Math.atan(Math.tan(editCamera.fov * Math.PI / 360) * Math.min(1, editCamera.aspect));
    const distance = Math.min(orbit.maxDistance, Math.max(2.6, radius / Math.sin(visibleAngle) * 1.02));
    const directions = { top: [0, 1, 0.0151], front: [0, 0, 1], right: [1, 0, 0] };
    const direction = editCamera.position.clone().sub(orbit.target).normalize();
    if (view === 'perspective' || direction.lengthSq() === 0) direction.copy(orbitOffset);
    else if (directions[view]) direction.fromArray(directions[view]).normalize();
    const destination = center.clone().addScaledVector(direction, distance);
    if (instant || window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      editCamera.position.copy(destination);
      orbit.target.copy(center);
      orbit.update();
    } else {
      focusMotion = {
        start: performance.now(), position: editCamera.position.clone(), target: orbit.target.clone(),
        destination, center: center.clone(),
      };
    }
    redraw = true;
  }

  function updateFly(dt) {
    if (flyPointer === null) return;
    flyDirection.set(-Math.sin(flyYaw) * Math.cos(flyPitch), Math.sin(flyPitch),
      -Math.cos(flyYaw) * Math.cos(flyPitch));
    flyRight.crossVectors(flyDirection, worldUp).normalize();
    const forward = Number(keys.has('KeyW')) - Number(keys.has('KeyS'));
    const side = Number(keys.has('KeyD')) - Number(keys.has('KeyA'));
    const lift = Number(keys.has('KeyE')) - Number(keys.has('KeyQ'));
    flyMotion.set(0, lift, 0).addScaledVector(flyDirection, forward).addScaledVector(flyRight, side);
    if (flyMotion.lengthSq() > 0) editCamera.position.addScaledVector(flyMotion.normalize(), 16 * dt);
    orbit.target.copy(editCamera.position).addScaledVector(flyDirection, flyDistance);
    editCamera.lookAt(orbit.target);
    redraw = true;
  }

  function setTool(mode, space, snapping, distance, angle) {
    if (!gizmo || gizmo.dragging) return;
    tool = mode;
    gizmo.setMode(mode === 'select' ? 'translate' : mode);
    gizmo.setSpace(space);
    gizmo.setTranslationSnap(snapping ? distance : null);
    gizmo.setRotationSnap(snapping ? angle * Math.PI / 180 : null);
    gizmo.setScaleSnap(snapping ? distance : null);
    refreshOutline();
  }

  function transformValues(mesh) {
    const rounded = (v) => Math.round(v * 1e4) / 1e4;
    return {
      position: mesh.position.toArray().map(rounded),
      size: mesh.scale.toArray().map(rounded),
      rotation: [mesh.rotation.x, mesh.rotation.y, mesh.rotation.z].map((v) => rounded(v * 180 / Math.PI)),
    };
  }

  gizmo?.addEventListener('change', () => { redraw = true; });
  gizmo?.addEventListener('dragging-changed', ({ value }) => {
    orbit.enabled = isStudio && !value;
    onDragging?.(value);
  });
  gizmo?.addEventListener('mouseDown', () => {
    canceled = false;
    focusMotion = null;
    canvas.focus({ preventScroll: true });
  });
  gizmo?.addEventListener('objectChange', () => {
    const mesh = gizmo.object;
    mesh.position.clamp(positionMin, positionMax);
    mesh.scale.clamp(sizeMin, sizeMax);
    refreshOutline();
    onPreview?.(transformValues(mesh));
    renderer.shadowMap.needsUpdate = true;
  });
  gizmo?.addEventListener('mouseUp', () => {
    if (!canceled && gizmo.object) onTransform?.(selected, transformValues(gizmo.object));
  });

  const positionMin = new Vector3(-250, -40, -250);
  const positionMax = new Vector3(250, 250, 250);
  const sizeMin = new Vector3(0.1, 0.1, 0.1);
  const sizeMax = new Vector3(128, 128, 128);

  function cancelTransform() {
    if (!gizmo?.dragging) return false;
    canceled = true;
    gizmo.reset();
    gizmo.pointerUp(null);
    return true;
  }

  function playtest(enabled) {
    if (!hasEditor || isStudio !== enabled) return;
    cancelTransform();
    focusMotion = null;
    clearInput();
    isStudio = !enabled;
    camera = enabled ? playCamera : editCamera;
    scene.background.set(enabled ? '#dceef8' : '#eaf2f1');
    scene.fog.color.copy(scene.background);
    orbit.enabled = !enabled;
    people.visible = enabled;
    grid.visible = !enabled;
    renderer.shadowMap.needsUpdate = true;
    if (enabled) {
      resetPlayer();
      yaw = 0;
      heading = 0;
    }
    setPlaying(enabled);
    refreshOutline();
  }

  function positionLight() {
    const anchor = bounds.isEmpty() ? spawn : bounds.getCenter(center);
    const range = bounds.isEmpty() ? 22 : Math.min(72, Math.max(16, bounds.getSize(partSize).length() * 0.46));
    sun.target.position.copy(anchor);
    sun.position.copy(anchor).add(new Vector3(36, 58, 19));
    Object.assign(sun.shadow.camera, { left: -range, right: range, top: range, bottom: -range });
    sun.shadow.camera.updateProjectionMatrix();
    renderer.shadowMap.needsUpdate = true;
  }

  function setScene(data) {
    const newWorld = data.id !== sceneId;
    sceneId = data.id;
    spawn.set(data.spawn.x, data.spawn.y, data.spawn.z);
    bounds.makeEmpty();
    colliderBounds.length = 0;

    const received = new Set();
    for (const object of data.objects) {
      received.add(object.id);
      let part = parts.get(object.id);
      if (!part) {
        const mesh = new Mesh(geometries[object.kind], new MeshStandardMaterial({ roughness: 0.85 }));
        mesh.userData.id = object.id;
        mesh.castShadow = true;
        mesh.receiveShadow = true;
        world.add(mesh);
        part = { mesh, box: new Box3() };
        parts.set(object.id, part);
      }
      const { mesh, box } = part;
      mesh.geometry = geometries[object.kind];
      mesh.material.color.set(object.color);
      mesh.position.fromArray(object.position);
      mesh.scale.fromArray(object.size);
      const rotation = object.rotation;
      mesh.rotation.set(rotation[0] * Math.PI / 180, rotation[1] * Math.PI / 180, rotation[2] * Math.PI / 180);
      mesh.updateMatrixWorld(true);
      box.setFromObject(mesh);
      bounds.union(box);
      if (object.solid) colliderBounds.push(box);
    }

    for (const [id, part] of parts) {
      if (received.has(id)) continue;
      part.mesh.removeFromParent();
      part.mesh.material.dispose();
      parts.delete(id);
    }

    if (newWorld) {
      selected = null;
      if (isStudio) frameOrbit(undefined, 'perspective', true);
      else resetPlayer();
    }

    world.updateMatrixWorld(true);
    refreshOutline();
    positionLight();
    redraw = true;
  }

  function setSelected(id) {
    selected = id;
    refreshOutline();
  }

  function setAvatars(peers, selfId) {
    if (isStudio) return;
    const present = new Set();
    for (const peer of peers) {
      if (peer.id === selfId) {
        authoritative.set(peer.x, peer.y, peer.z);
        if (networked && !hasAuthority) {
          position.copy(authoritative);
          hasAuthority = true;
          fallSpeed = 0;
          grounded = false;
        }
        continue;
      }
      present.add(peer.id);
      let data = remoteAvatars.get(peer.id);
      if (!data) {
        data = avatar(geometries, peer.color);
        data.group.position.set(peer.x, peer.y, peer.z);
        data.group.rotation.y = Number.isFinite(peer.yaw) ? peer.yaw : 0;
        remoteAvatars.set(peer.id, data);
        people.add(data.group);
      }
      data.destination.set(peer.x, peer.y, peer.z);
      data.yaw = Number.isFinite(peer.yaw) ? peer.yaw : 0;
    }
    for (const [id, data] of remoteAvatars) {
      if (present.has(id)) continue;
      disposeAvatar(data);
      remoteAvatars.delete(id);
    }
    renderer.shadowMap.needsUpdate = true;
    redraw = true;
  }

  function moveHorizontal(axis, distance) {
    if (distance === 0) return;
    const previous = position[axis];
    const limit = 320 - AVATAR_RADIUS;
    position[axis] = Math.max(-limit, Math.min(limit, previous + distance));
    const crossAxis = axis === 'x' ? 'z' : 'x';
    for (const box of colliderBounds) {
      if (!overlapsHeight(box, position.y) || position[crossAxis] + AVATAR_RADIUS <= box.min[crossAxis] ||
        position[crossAxis] - AVATAR_RADIUS >= box.max[crossAxis]) continue;
      const near = distance > 0 ? box.min[axis] - AVATAR_RADIUS : box.max[axis] + AVATAR_RADIUS;
      const crossed = distance > 0 ? previous <= near && position[axis] > near :
        previous >= near && position[axis] < near;
      if (!crossed) continue;
      const top = box.max.y;
      if (grounded && top - position.y <= STEP_HEIGHT &&
        !colliderBounds.some(other =>
          overlapsHeight(other, top) && overlapsFootprint(other, position.x, position.z))) {
        position.y = top;
      } else {
        position[axis] = near;
      }
    }
  }

  function moveVertical(dt) {
    fallSpeed -= GRAVITY * dt;
    const previous = position.y;
    let next = previous + fallSpeed * dt;
    grounded = false;
    for (const box of colliderBounds) {
      if (!overlapsFootprint(box, position.x, position.z)) continue;
      if (fallSpeed <= 0 && previous >= box.max.y - EPSILON && next <= box.max.y) {
        next = box.max.y;
        grounded = true;
      } else if (fallSpeed > 0 && previous + AVATAR_HEIGHT <= box.min.y && next + AVATAR_HEIGHT >= box.min.y) {
        next = box.min.y - AVATAR_HEIGHT;
      }
    }
    if (grounded || (next < previous + fallSpeed * dt && fallSpeed > 0)) fallSpeed = 0;
    position.y = next;
    const floor = bounds.isEmpty() ? spawn.y : bounds.min.y;
    if (position.y < Math.max(-40, Math.min(spawn.y, floor) - 24)) resetPlayer();
  }

  function updatePlayer(dt, now) {
    if (playing && sceneId) {
      const left = Number(keys.has('KeyA') || keys.has('ArrowLeft'));
      const right = Number(keys.has('KeyD') || keys.has('ArrowRight'));
      const forward = Number(keys.has('KeyW') || keys.has('ArrowUp'));
      const backward = Number(keys.has('KeyS') || keys.has('ArrowDown'));
      const strafe = right - left;
      const advance = forward - backward;
      const speed = WALK_SPEED * dt / Math.max(1, Math.hypot(strafe, advance));
      const x = strafe * Math.cos(yaw) - advance * Math.sin(yaw);
      const z = -strafe * Math.sin(yaw) - advance * Math.cos(yaw);
      const previousX = position.x;
      const previousY = position.y;
      const previousZ = position.z;
      const previousHeading = heading;
      moveHorizontal('x', x * speed);
      moveHorizontal('z', z * speed);
      if (strafe || advance) heading = Math.atan2(-x, -z);
      if (jumped && grounded) fallSpeed = JUMP_SPEED;
      jumped = false;
      moveVertical(dt);
      if (networked) {
        sendInput(strafe, advance, now);
        if (hasAuthority) {
          const drift = position.distanceTo(authoritative);
          if (drift > 3.5) {
            position.copy(authoritative);
            fallSpeed = 0;
            grounded = false;
          } else if (!strafe && !advance && grounded && Math.abs(position.y - authoritative.y) < 0.2) {
            const recovery = 1 - Math.exp(-5 * dt);
            position.x += (authoritative.x - position.x) * recovery;
            position.z += (authoritative.z - position.z) * recovery;
          }
        }
      }
      if (previousX !== position.x || previousY !== position.y ||
        previousZ !== position.z || previousHeading !== heading) {
            redraw = true;
        renderer.shadowMap.needsUpdate = true;
      }
    }

    self.group.position.copy(position);
    self.group.rotation.y = heading;
    cameraTarget.copy(position);
    cameraTarget.y += 1.14;
    cameraOffset.set(Math.sin(yaw) * Math.cos(pitch), Math.sin(pitch), Math.cos(yaw) * Math.cos(pitch));
    cameraRay.set(cameraTarget, cameraOffset);
    let distance = zoom;
    for (const box of colliderBounds) {
      // A camera starting inside a collider should move away freely.
      if (box.containsPoint(cameraTarget)) continue;
      const hit = cameraRay.intersectBox(box, intersection);
      if (hit) distance = Math.min(distance, Math.max(0.35, cameraTarget.distanceTo(hit) - 0.2));
    }
    self.group.visible = distance > 1.15;
    camera.position.copy(cameraTarget).addScaledVector(cameraOffset, distance);
    camera.lookAt(cameraTarget);

    const blend = 1 - Math.exp(-14 * dt);
    for (const data of remoteAvatars.values()) {
      const difference = data.yaw - data.group.rotation.y;
      const angle = Math.atan2(Math.sin(difference), Math.cos(difference));
      const distanceSquared = data.group.position.distanceToSquared(data.destination);
      if (distanceSquared < 0.000001 && Math.abs(angle) < 0.001) continue;
      data.group.position.lerp(data.destination, blend);
      data.group.rotation.y += angle * blend;
      redraw = true;
      renderer.shadowMap.needsUpdate = true;
    }
  }

  function getPose() {
    return { x: position.x, y: position.y, z: position.z, yaw: heading };
  }

  function sendInput(x, z, now, force = false) {
    const cameraYaw = Math.atan2(Math.sin(yaw), Math.cos(yaw));
    const key = [x, z, Math.round(cameraYaw * 50), jumpSequence].join('/');
    if (!force && (now - lastInputTime < 35 || (key === lastInputKey && now - lastInputTime < 180))) return;
    lastInputTime = now;
    lastInputKey = key;
    onInput?.({ x, z, yaw: cameraYaw, jump: jumpSequence });
  }

  function clearInput() {
    keys.clear();
    jumped = false;
    pointerDown = null;
    flyPointer = null;
    if (networked) sendInput(0, 0, performance.now(), true);
    if (orbit) orbit.enabled = isStudio && !gizmo.dragging;
  }

  function setPlaying(enabled) {
    playing = Boolean(enabled) && !isStudio;
    if (!playing) clearInput();
    redraw = true;
  }

  function setNetworked(enabled) {
    networked = enabled;
    hasAuthority = false;
    lastInputKey = '';
    lastInputTime = 0;
  }

  function listen(target, event, handler, options) {
    target.addEventListener(event, handler, { ...options, signal: listeners.signal });
  }

  listen(canvas, 'pointerdown', event => {
    focusMotion = null;
    if (isStudio && event.button === 2 && !gizmo.dragging) {
      canvas.focus({ preventScroll: true });
      editCamera.getWorldDirection(flyDirection);
      flyYaw = Math.atan2(-flyDirection.x, -flyDirection.z);
      flyPitch = Math.asin(flyDirection.y);
      flyDistance = Math.max(1, editCamera.position.distanceTo(orbit.target));
      flyPointer = event.pointerId;
      orbit.enabled = false;
      refreshOutline();
      canvas.setPointerCapture(event.pointerId);
      return;
    }
    if (gizmo?.dragging || (event.button !== 0 && (!playing || event.button !== 2))) return;
    canvas.focus({ preventScroll: true });
    pointerDown = { id: event.pointerId, x: event.clientX, y: event.clientY, moved: false };
    if (!isStudio && playing) canvas.setPointerCapture(event.pointerId);
  });

  listen(canvas, 'pointermove', event => {
    if (flyPointer === event.pointerId) {
      flyYaw -= event.movementX * 0.005;
      flyPitch = Math.max(-1.52, Math.min(1.52, flyPitch - event.movementY * 0.005));
      redraw = true;
      return;
    }
    if (pointerDown?.id !== event.pointerId) return;
    const dx = event.clientX - pointerDown.x;
    const dy = event.clientY - pointerDown.y;
    if (Math.hypot(dx, dy) > 4) pointerDown.moved = true;
    if (playing) {
      yaw -= dx * 0.008;
      pitch = Math.max(-0.13, Math.min(1.24, pitch + dy * 0.008));
      pointerDown.x = event.clientX;
      pointerDown.y = event.clientY;
      redraw = true;
    }
  });

  function stopFly() {
    if (flyPointer === null) return;
    flyPointer = null;
    keys.clear();
    orbit.enabled = isStudio;
    refreshOutline();
  }

  listen(canvas, 'pointerup', event => {
    if (flyPointer === event.pointerId) stopFly();
    if (pointerDown?.id !== event.pointerId) return;
    const { moved, x, y } = pointerDown;
    pointerDown = null;
    if (!isStudio || moved || Math.hypot(x - event.clientX, y - event.clientY) > 4) return;
    const rect = canvas.getBoundingClientRect();
    if (!rect.width || !rect.height) return;
    pointer.set((event.clientX - rect.left) / rect.width * 2 - 1, 1 - (event.clientY - rect.top) / rect.height * 2);
    camera.updateMatrixWorld();
    raycaster.setFromCamera(pointer, camera);
    const hit = raycaster.intersectObjects(world.children, false)[0];
    onSelect?.(hit?.object.userData.id ?? null);
  });
  listen(canvas, 'pointercancel', () => {
    cancelTransform();
    pointerDown = null;
    stopFly();
  });
  listen(canvas, 'lostpointercapture', () => { stopFly(); });
  listen(canvas, 'blur', () => { cancelTransform(); stopFly(); clearInput(); });
  listen(canvas, 'contextmenu', event => event.preventDefault());
  listen(canvas, 'wheel', event => {
    focusMotion = null;
    if (!playing) return;
    event.preventDefault();
    zoom = Math.max(2.5, Math.min(14, zoom * Math.exp(event.deltaY * 0.0018)));
    redraw = true;
  }, { passive: false });

  listen(window, 'keydown', event => {
    if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey ||
      event.target?.matches?.('input, textarea, select, button, [contenteditable]')) return;
    if (flyPointer !== null && /^Key[WASDQE]$/.test(event.code)) {
      event.preventDefault();
      keys.add(event.code);
    } else if (playing && MOVE_KEYS.has(event.code)) {
      event.preventDefault();
      if (event.code === 'Space' && !event.repeat) {
        jumped = true;
        jumpSequence++;
      }
      keys.add(event.code);
    }
  });
  listen(window, 'keyup', event => keys.delete(event.code));
  listen(window, 'blur', clearInput);
  listen(document, 'visibilitychange', () => {
    if (document.hidden) clearInput();
    else {
      lastFrame = 0;
      redraw = true;
    }
  });
  listen(canvas, 'webglcontextlost', event => {
    event.preventDefault();
    contextLost = true;
    onError?.(new Error('The 3D view lost its graphics connection.'));
  });
  listen(canvas, 'webglcontextrestored', () => {
    contextLost = false;
    redraw = true;
    renderer.shadowMap.needsUpdate = true;
    onRestore?.();
  });

  function resize() {
    const { width, height } = canvas.getBoundingClientRect();
    visible = Boolean(width && height);
    if (!visible) { lastFrame = 0; return; }
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.75));
    renderer.setSize(Math.round(width), Math.round(height), false);
    for (const view of [playCamera, editCamera]) {
      if (!view) continue;
      view.aspect = width / height;
      view.updateProjectionMatrix();
    }
    redraw = true;
  }

  function draw(now) {
    frame = requestAnimationFrame(draw);
    if (contextLost || document.hidden || !visible) return;
    const dt = lastFrame ? Math.min((now - lastFrame) / 1000, 0.05) : 0;
    lastFrame = now;
    let orbitMoved = false;
    if (isStudio) {
      if (focusMotion) {
        const progress = Math.min(1, (now - focusMotion.start) / 230);
        const blend = 1 - (1 - progress) ** 3;
        editCamera.position.lerpVectors(focusMotion.position, focusMotion.destination, blend);
        orbit.target.lerpVectors(focusMotion.target, focusMotion.center, blend);
        if (progress === 1) focusMotion = null;
        redraw = true;
      }
      if (flyPointer !== null) updateFly(dt);
      else if (!gizmo.dragging) orbitMoved = orbit.update();
    } else {
      updatePlayer(dt, now);
    }
    if (redraw || orbitMoved) renderer.render(scene, camera);
    redraw = false;
  }

  const observer = new ResizeObserver(resize);
  observer.observe(canvas);
  resize();
  frameOrbit(undefined, 'perspective', true);
  positionLight();
  frame = requestAnimationFrame(draw);

  return {
    setScene,
    setSelected,
    setAvatars,
    setPlaying,
    setNetworked,
    setTool,
    cancelTransform,
    playtest,
    restart() {
      jumpSequence = 0;
      yaw = 0;
      heading = 0;
      pitch = 0.34;
      zoom = 8.5;
      resetPlayer();
    },
    focus: frameOrbit,
    getPose,
    dispose() {
      if (disposed) return;
      disposed = true;
      listeners.abort();
      observer.disconnect();
      cancelAnimationFrame(frame);
      gizmo?.dispose();
      orbit?.dispose();
      grid?.geometry.dispose();
      grid?.material.dispose();
      outline?.geometry.dispose();
      outline?.material.dispose();
      sun.shadow.dispose();
      for (const part of parts.values()) part.mesh.material.dispose();
      for (const data of remoteAvatars.values()) disposeAvatar(data);
      disposeAvatar(self);
      for (const geometry of Object.values(geometries)) geometry.dispose();
      renderer.dispose();
    },
  };
}
