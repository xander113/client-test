export const MAX_SCENE_BYTES = 256 * 1024;
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
  if (input.schemaVersion !== 1) throw new Error('This project format version is unsupported.');
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
      size: Array.from(object.size, (value) => asNumber(value, 'Object size', 0.1, 128)),
      color: object.color.toLowerCase(),
      solid: object.solid,
    };
  });
  return {
    schemaVersion: 1,
    id: validateWorldId(id),
    name: asText(name, 'Project name', 1, 80),
    description: asText(description, 'Description', 0, 400),
    spawn: { x, y, z },
    objects: validatedObjects,
  };
}

const part = (id, name, kind, position, size, color, solid = true) =>
  ({ id, name, kind, position, size, color, solid });

export function createScene(name = 'Untitled world') {
  return validateScene({
    schemaVersion: 1,
    id: `world-${crypto.randomUUID()}`,
    name,
    description: '',
    spawn: { x: 0, y: 0, z: 5 },
    objects: [part('ground', 'Ground', 'box', [0, -0.5, 0], [34, 1, 34], '#91bfa0')],
  });
}

const boxes = (name, entries) => entries.map(([position, size, color], index) =>
  part(`${name}-${index + 1}`, `${name[0].toUpperCase()}${name.slice(1)} ${index + 1}`,
    'box', position, size, color));

const tree = (x, z, i) => [
  part(`trunk-${i}`, 'Trunk', 'cylinder', [x, 1.2, z], [0.34, 2.4, 0.34], '#936a49'),
  part(`canopy-${i}`, 'Canopy', 'sphere', [x, 2.9, z], [2.6, 2.8, 2.6],
    i % 2 ? '#2b885d' : '#69b45b', false),
];

const terrace = {
  schemaVersion: 1,
  id: 'terrace-park',
  name: 'Terrace Park',
  description: 'Climb the green terraces and explore the pavilion above the park.',
  spawn: { x: 0, y: 0, z: 12 },
  objects: [
    part('lawn', 'Park foundation', 'box', [0, -1, 0], [36, 2, 32], '#7bab7a'),
    ...boxes('walkway', [
      [[0, 0.06, 6], [5, 0.12, 16], '#dfd4a9'],
      [[0, 0.5, -1], [7, 1, 4], '#cef09c'],
      [[0, 1.1, -4], [10, 2.2, 4], '#a4dc77'],
      [[0, 1.7, -7], [14, 3.4, 4], '#7ac05e'],
      [[0, 2.3, -11], [19, 4.6, 6], '#4c9b58'],
    ]),
    ...boxes('pavilion', [
      [[0, 4.7, -10.8], [12, 0.22, 5], '#f6db98'],
      [[-5.5, 6.15, -13], [0.44, 3, 0.44], '#fbecce'],
      [[5.5, 6.15, -13], [0.44, 3, 0.44], '#fbecce'],
      [[-5.5, 6.15, -8.6], [0.44, 3, 0.44], '#fbecce'],
      [[5.5, 6.15, -8.6], [0.44, 3, 0.44], '#fbecce'],
      [[0, 7.7, -10.8], [12.6, 0.26, 5.6], '#f8ba67'],
      [[0, 8, -10.8], [10.8, 0.34, 4.5], '#fa7543'],
      [[0, 8.35, -10.8], [8.1, 0.36, 3.1], '#ef6043'],
    ]),
    ...[[-12, 8], [12, 7], [-13, -4], [13, -4], [-8, 12], [8, 13]].flatMap(([x, z], i) => tree(x, z, i)),
    ...boxes('seat', [
      [[-6.5, 0.38, 3.3], [2.6, 0.76, 1.1], '#f49d61'],
      [[7, 0.38, 3.3], [2.6, 0.76, 1.1], '#f49d61'],
    ]),
  ],
};

const dunes = {
  schemaVersion: 1,
  id: 'dune-circuit',
  name: 'Dune Circuit',
  description: 'Cross a sunlit canyon on a route of switchbacks and stepping stones.',
  spawn: { x: 0, y: 0, z: 10 },
  objects: [
    part('sand', 'Canyon basin', 'box', [0, -2, 0], [37, 1, 31], '#edbd7e'),
    ...boxes('platform', [
      [[0, -0.77, 11], [8, 1.54, 6], '#ffe2aa'],
      [[-3, -0.4, 6.5], [4, 2.2, 3], '#f7c185'],
      [[-6, 0, 3], [4, 3, 3], '#eb9970'],
      [[-10, 0.4, -0.7], [5, 3.8, 4], '#e78d5c'],
      [[-8, 0.84, -5.2], [4, 4.68, 4], '#f6ce93'],
      [[-3.8, 1.3, -7.5], [4, 5.6, 3.8], '#e68e65'],
      [[1, 1.7, -9.7], [5, 6.4, 5], '#e59a67'],
      [[8.5, 1.7, -9.7], [11, 6.4, 7], '#e6a161'],
      [[11.5, -0.36, 3.6], [4, 2.28, 6], '#efb479'],
      [[11.5, 0.34, -2.3], [4, 3.68, 6], '#f0c38d'],
    ]),
    ...boxes('marker', [
      [[4.8, 4, -7.6], [0.4, 1.4, 0.4], '#dce7c8'],
      [[12.8, 4, -7.6], [0.4, 1.4, 0.4], '#dce7c8'],
      [[8.8, 4.8, -7.6], [8.5, 0.26, 0.5], '#449d93'],
    ]),
    ...[[-15, 4], [-13, -11], [15, 8], [5, 7], [-5, -13]].map(([x, z], i) =>
      part(`column-${i}`, 'Sandstone column', 'cylinder',
        [x, 1.05, z], [2.5, 5.1, 2.5], '#c67859')),
  ],
};

const tidebreak = {
  schemaVersion: 1,
  id: 'tidebreak',
  name: 'Tidebreak',
  description: 'Follow the piers to the signal tower and look out over the harbor.',
  spawn: { x: 0, y: 0, z: 12 },
  objects: [
    part('water', 'Harbor', 'box', [0, -1.5, 0], [42, 1, 34], '#54aec0', false),
    ...boxes('pier', [
      [[0, -0.28, 9], [15, 0.56, 11], '#e4c5a4'],
      [[-5, 0.18, 0.3], [5, 0.72, 9], '#e9ccac'],
      [[0, 0.3, -4], [15, 0.9, 4], '#ebc698'],
      [[6, 0.5, -9], [10, 1.3, 7], '#d5a989'],
      [[-10, 0.1, -10], [6, 0.6, 9], '#d9ad8a'],
      [[-9, 0.24, -5], [5, 0.6, 7], '#c69a77'],
    ]),
    part('signal', 'Signal tower', 'cylinder', [7, 3.48, -9], [4.8, 4.7, 4.8], '#fff4d5'),
    part('signal-band', 'Signal band', 'cylinder', [7, 4.8, -9], [4.9, 0.84, 4.9], '#d26054'),
    part('signal-deck', 'Observation deck', 'cylinder', [7, 6, -9], [6, 0.5, 6], '#476b7a'),
    part('lamp', 'Signal lamp', 'sphere', [7, 6.8, -9], [1.7, 1.7, 1.7], '#f7ca63'),
    ...boxes('cargo', [
      [[-4, 0.6, 8], [2.4, 1.2, 2], '#d46f5f'],
      [[-4, 1.6, 8], [1.6, 0.8, 1.8], '#f1b66b'],
      [[-10.8, 1.07, -10.8], [3.3, 1.58, 2.8], '#418b9d'],
      [[2.4, 0.5, 5], [2.5, 1, 3.2], '#93b88b'],
    ]),
    ...[[-6, 4], [-6, -3], [4, -3], [10, -7], [-10, -8], [-10, -13]].map(([x, z], i) =>
      part(`bollard-${i}`, 'Mooring bollard', 'cylinder',
        [x, 0.68, z], [0.45, 1.35, 0.45], '#445a66')),
  ],
};

export const starterWorlds = [terrace, dunes, tidebreak].map(validateScene);
