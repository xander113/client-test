export const MAX_OBJECTS = 400;
export const KINDS = Object.freeze(['box', 'sphere', 'cylinder']);

function asRecord(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object.`);
  }
  return value;
}

function asText(value, label, min, max) {
  if (typeof value !== 'string' || value.length < min || value.length > max ||
      (min > 0 && !value.trim()) || /[\u0000-\u001f\u007f]/u.test(value)) {
    throw new Error(`${label} must contain ${min} to ${max} characters.`);
  }
  return value;
}

function asNumber(value, label, min, max) {
  if (!Number.isFinite(value) || value < min || value > max) {
    throw new Error(`${label} must be a number between ${min} and ${max}.`);
  }
  return value;
}

export function validateWorldId(id) {
  if (typeof id !== 'string' || !/^[a-z0-9][a-z0-9-]{0,63}$/u.test(id)) {
    throw new Error('World and object IDs must use lowercase letters, digits or dashes.');
  }
  return id;
}

function validatePosition(position, label) {
  if (!Array.isArray(position) || position.length !== 3) {
    throw new Error(`${label} must have exactly three coordinates.`);
  }
  return [
    asNumber(position[0], `${label} X`, -250, 250),
    asNumber(position[1], `${label} Y`, -40, 250),
    asNumber(position[2], `${label} Z`, -250, 250),
  ];
}

export function validateScene(input) {
  asRecord(input, 'Project');
  if (input.schemaVersion !== 2) throw new Error('This project format version is unsupported.');
  const { id, name, description, spawn, objects } = input;
  asRecord(spawn, 'Spawn');
  const [x, y, z] = validatePosition([spawn.x, spawn.y, spawn.z], 'Spawn');
  if (!Array.isArray(objects) || objects.length > MAX_OBJECTS) {
    throw new Error(`A project may contain up to ${MAX_OBJECTS} objects.`);
  }

  const ids = new Set();
  const validatedObjects = Array.from(objects, (object) => {
    asRecord(object, 'Scene object');
    const objectId = validateWorldId(object.id);
    if (ids.has(objectId)) throw new Error(`Object ID "${objectId}" is duplicated.`);
    ids.add(objectId);
    if (!KINDS.includes(object.kind)) throw new Error('Unknown object geometry.');
    if (!Array.isArray(object.rotation) || object.rotation.length !== 3) {
      throw new Error('Rotation must have three angles.');
    }
    if (!Array.isArray(object.size) || object.size.length !== 3) {
      throw new Error('Object size must have exactly three dimensions.');
    }
    if (typeof object.color !== 'string' || !/^#[0-9a-f]{6}$/iu.test(object.color)) {
      throw new Error('Object color must use six hexadecimal digits.');
    }
    if (typeof object.solid !== 'boolean') throw new Error('Object solidity must be true or false.');
    return {
      id: objectId,
      name: asText(object.name, 'Object name', 1, 80),
      kind: object.kind,
      position: validatePosition(object.position, 'Object position'),
      rotation: Array.from(object.rotation, (value) => asNumber(value, 'Rotation', -180, 180)),
      size: Array.from(object.size, (value) => asNumber(value, 'Object size', 0.1, 128)),
      color: object.color.toLowerCase(),
      solid: object.solid,
    };
  });
  return {
    schemaVersion: 2,
    id: validateWorldId(id),
    name: asText(name, 'Project name', 1, 80),
    description: asText(description, 'Description', 0, 400),
    spawn: { x, y, z },
    objects: validatedObjects,
  };
}

const part = (id, name, kind, position, size, color, solid = true) =>
  ({ id, name, kind, position, rotation: [0, 0, 0], size, color, solid });

export function createScene(name = 'Untitled world') {
  return validateScene({
    schemaVersion: 2,
    id: `world-${crypto.randomUUID()}`,
    name,
    description: '',
    spawn: { x: 0, y: 0, z: 5 },
    objects: [part('ground', 'Ground', 'box', [0, -0.5, 0], [34, 1, 34], '#91bfa0')],
  });
}
