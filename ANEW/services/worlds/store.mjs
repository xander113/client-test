import { randomUUID } from 'node:crypto';
import { lstat, mkdir, open, readFile, readdir, rename, unlink } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { MAX_SCENE_BYTES, starterWorlds, validateScene } from '../../shared/scene.mjs';
import { RequestError } from './http.mjs';

const maxWorlds = 128;
const worldFilename = /^world-([a-z0-9][a-z0-9-]{0,63})\.json$/;

async function writeScene(target, body) {
  const temporary = `${target}.${randomUUID()}.tmp`;
  try {
    const file = await open(temporary, 'wx', 0o600);
    try {
      await file.writeFile(body);
      await file.sync();
    } finally {
      await file.close();
    }
    await rename(temporary, target);
  } finally {
    await unlink(temporary).catch(() => {});
  }
}

export async function openWorldStore(dataDir) {
  const worlds = new Map(starterWorlds.map((scene) => [scene.id, validateScene(scene)]));
  const directory = dataDir && resolve(dataDir);
  const files = new Map();
  let pendingSave = Promise.resolve();

  async function listIds() {
    const ids = new Set(worlds.keys());
    if (directory) {
      for (const entry of await readdir(directory, { withFileTypes: true })) {
        if (!entry.isFile()) continue;
        const match = worldFilename.exec(entry.name);
        if (!match) continue;
        ids.add(match[1]);
        if (ids.size > maxWorlds) throw new Error('World storage contains too many scenes');
      }
      for (const id of files.keys()) {
        if (!ids.has(id)) files.delete(id);
      }
    }
    return ids;
  }

  async function get(id) {
    if (!directory) return worlds.get(id);
    const path = join(directory, `world-${id}.json`);
    try {
      const details = await lstat(path, { bigint: true });
      if (!details.isFile() || details.size > MAX_SCENE_BYTES) throw new Error('Storage limit exceeded');
      // Detect atomic replacements from another running desktop app as well
      // as modifications made by an operator on the hosting machine.
      const version = `${details.mtimeNs}/${details.ino}/${details.size}`;
      const saved = files.get(id);
      if (saved?.version === version) return saved.scene;

      const scene = validateScene(JSON.parse(await readFile(path, 'utf8')));
      if (scene.id !== id) throw new Error('Scene identifier does not match filename');
      const concurrent = files.get(id);
      if (concurrent?.version === version) return concurrent.scene;
      files.set(id, { version, scene });
      return scene;
    } catch (error) {
      if (error.code !== 'ENOENT') throw new Error(`Invalid stored world ${id}`, { cause: error });
      files.delete(id);
      return worlds.get(id);
    }
  }

  async function list() {
    const scenes = await Promise.all(Array.from(await listIds(), get));
    return scenes.filter(Boolean).map(({ id, name, description }) => ({ id, name, description }));
  }

  if (directory) {
    await mkdir(directory, { recursive: true });
    await list();
  }

  return {
    get,
    list,
    put(scene) {
      const save = pendingSave.then(async () => {
        const ids = await listIds();
        if (ids.size >= maxWorlds && !ids.has(scene.id)) {
          throw new RequestError(409, 'World storage is full');
        }
        const body = JSON.stringify(scene);
        if (Buffer.byteLength(body) > MAX_SCENE_BYTES) {
          throw new RequestError(413, 'World scene is too large');
        }
        if (directory) {
          await writeScene(join(directory, `world-${scene.id}.json`), body);
          files.delete(scene.id);
          return;
        }
        worlds.set(scene.id, scene);
      });
      pendingSave = save.catch(() => {});
      return save;
    },
    close: () => pendingSave,
  };
}
