import {
  ACESFilmicToneMapping, Box3, BoxGeometry, BoxHelper, CapsuleGeometry, Color,
  CylinderGeometry, DirectionalLight, FogExp2, GridHelper, Group, HemisphereLight,
  Mesh, MeshStandardMaterial, PCFShadowMap, PerspectiveCamera, Ray, Raycaster,
  Scene, SphereGeometry, Vector2, Vector3, WebGLRenderer,
} from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

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
export function createViewport(canvas, { mode = 'studio', onSelect, onPose, onError, onRestore } = {}) {
  const isStudio = mode === 'studio';
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

  const camera = new PerspectiveCamera(isStudio ? 45 : 62, 1, 0.095, 480);
  const orbit = isStudio ? new OrbitControls(camera, canvas) : null;
  if (orbit) {
    orbit.enableDamping = true;
    orbit.dampingFactor = 0.12;
    orbit.enablePan = true;
    orbit.maxDistance = 380;
    orbit.maxPolarAngle = Math.PI * 0.495;
    orbit.minDistance = 1;
  }

  const grid = isStudio ? new GridHelper(320, 320, '#63898b', '#7f9f9e') : null;
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
  const outline = isStudio ? new BoxHelper(undefined, '#09b734') : null;
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
  const self = isStudio ? null : avatar(geometries, '#09b734');
  if (self) people.add(self.group);
  const keys = new Set();
  const raycaster = new Raycaster();
  const pointer = new Vector2();
  const cameraRay = new Ray();
  const cameraTarget = new Vector3();
  const cameraOffset = new Vector3();
  const intersection = new Vector3();
  const center = new Vector3();
  const orbitOffset = new Vector3(1, 0.71, 1).normalize();
  const listeners = new AbortController();
  let sceneId = null;
  let pointerDown = null;
  let selected = null;
  let playing = false;
  let moving = false;
  let jumped = false;
  let grounded = false;
  let frame = 0;
  let lastFrame = 0;
  let lastPose = 0;
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
    outline.visible = Boolean(part);
    if (part) outline.setFromObject(part.mesh);
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
    moving = true;
    renderer.shadowMap.needsUpdate = true;
    redraw = true;
  }

  function frameOrbit(id) {
    if (!orbit) return;
    const target = parts.get(id)?.box || bounds;
    if (target.isEmpty()) {
      center.copy(spawn);
      partSize.set(10, 6, 10);
    } else {
      target.getCenter(center);
      target.getSize(partSize);
    }
    const radius = Math.max(2, partSize.length() * 0.5);
    const fov = camera.fov * Math.PI / 360;
    const visibleAngle = Math.atan(Math.tan(fov) * Math.min(1, camera.aspect));
    const distance = Math.min(orbit.maxDistance, Math.max(4.5, radius / Math.sin(visibleAngle) * 1.06));
    camera.position.copy(center).addScaledVector(orbitOffset, distance);
    orbit.target.copy(center);
    orbit.update();
    redraw = true;
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
      partSize.copy(mesh.scale).multiplyScalar(0.5);
      box.min.copy(mesh.position).sub(partSize);
      box.max.copy(mesh.position).add(partSize);
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
      if (isStudio) frameOrbit();
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
      if (peer.id === selfId) continue;
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
      if (previousX !== position.x || previousY !== position.y ||
        previousZ !== position.z || previousHeading !== heading) {
        moving = true;
        redraw = true;
        renderer.shadowMap.needsUpdate = true;
      }
      // Keep the final pose after input stops, while avoiding frame-rate network traffic.
      if (now - lastPose >= 65 && moving) {
        onPose?.(getPose());
        lastPose = now;
        moving = false;
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

  function clearInput() {
    keys.clear();
    jumped = false;
    pointerDown = null;
  }

  function setPlaying(enabled) {
    playing = Boolean(enabled) && !isStudio;
    if (!playing) clearInput();
    redraw = true;
  }

  function listen(target, event, handler, options) {
    target.addEventListener(event, handler, { ...options, signal: listeners.signal });
  }

  listen(canvas, 'pointerdown', event => {
    if (event.button !== 0 && (!playing || event.button !== 2)) return;
    pointerDown = { id: event.pointerId, x: event.clientX, y: event.clientY, moved: false };
    if (!isStudio && playing) canvas.setPointerCapture(event.pointerId);
  });
  listen(canvas, 'pointermove', event => {
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
  listen(canvas, 'pointerup', event => {
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
  listen(canvas, 'pointercancel', () => { pointerDown = null; });
  listen(canvas, 'lostpointercapture', () => { pointerDown = null; });
  listen(canvas, 'blur', clearInput);
  listen(canvas, 'contextmenu', event => event.preventDefault());
  if (!isStudio) {
    listen(canvas, 'wheel', event => {
      if (!playing) return;
      event.preventDefault();
      zoom = Math.max(2.5, Math.min(14, zoom * Math.exp(event.deltaY * 0.0018)));
      redraw = true;
    }, { passive: false });
  }

  listen(window, 'keydown', event => {
    if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey ||
      event.target?.matches?.('input, textarea, select, button, [contenteditable]')) return;
    if (isStudio && event.code === 'KeyF' && document.activeElement === canvas) {
      frameOrbit(selected);
    } else if (playing && MOVE_KEYS.has(event.code)) {
      event.preventDefault();
      if (event.code === 'Space' && !event.repeat) jumped = true;
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
    if (!width || !height) return;
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.75));
    renderer.setSize(Math.round(width), Math.round(height), false);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
    redraw = true;
  }

  function draw(now) {
    frame = requestAnimationFrame(draw);
    if (contextLost || document.hidden) return;
    const dt = lastFrame ? Math.min((now - lastFrame) / 1000, 0.05) : 0;
    lastFrame = now;
    const orbitMoved = orbit?.update();
    if (self) updatePlayer(dt, now);
    if (redraw || orbitMoved) renderer.render(scene, camera);
    redraw = false;
  }

  const observer = new ResizeObserver(resize);
  observer.observe(canvas);
  resize();
  frameOrbit();
  positionLight();
  frame = requestAnimationFrame(draw);

  return {
    setScene,
    setSelected,
    setAvatars,
    setPlaying,
    focus: frameOrbit,
    getPose,
    dispose() {
      if (disposed) return;
      disposed = true;
      listeners.abort();
      observer.disconnect();
      cancelAnimationFrame(frame);
      orbit?.dispose();
      grid?.geometry.dispose();
      grid?.material.dispose();
      outline?.geometry.dispose();
      outline?.material.dispose();
      sun.shadow.dispose();
      for (const part of parts.values()) part.mesh.material.dispose();
      for (const data of remoteAvatars.values()) disposeAvatar(data);
      if (self) disposeAvatar(self);
      for (const geometry of Object.values(geometries)) geometry.dispose();
      renderer.dispose();
    },
  };
}
