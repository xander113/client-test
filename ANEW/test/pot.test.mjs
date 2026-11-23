import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { decodeSessionMessage, WorldApi } from '../desktop/world-api.mjs';
import { startRenderService } from '../services/render/service.mjs';
import { startWorldService } from '../services/worlds/service.mjs';
import { createScene, starterWorlds, validateScene } from '../shared/scene.mjs';

test('world format validates geometry, projects and scene identifiers', () => {
  for (const scene of starterWorlds) assert.deepEqual(validateScene(scene), scene);
  const scene = createScene();
  const first = scene.objects[0];
  assert.throws(() => validateScene({ ...scene, id: '../outside' }), /IDs/u);
  assert.throws(() => validateScene({ ...scene, schemaVersion: 2 }), /version/u);
  assert.throws(() => validateScene({ ...scene, objects: [first, first] }), /duplicated/u);
  assert.throws(() => validateScene({ ...scene, spawn: { ...scene.spawn, y: Infinity } }), /Spawn/u);
  assert.throws(() => validateScene({ ...scene, objects: [{ ...first, size: [1, 0, 1] }] }), /size/u);
  assert.deepEqual(validateScene({ ...scene, secret: 'ignored' }), scene);
});

function watch(socket) {
  const messages = [];
  socket.on('message', (data) => {
    const message = decodeSessionMessage(data);
    if (message) messages.push(message);
  });
  return async (predicate) => {
    for (let attempt = 0; attempt < 150; attempt++) {
      const message = messages.find(predicate);
      if (message) return message;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error('Timed out waiting for a world session message.');
  };
}

test('desktop API, live sessions, disk catalog and PRS work over loopback', async (t) => {
  const dataDir = await mkdtemp(join(tmpdir(), 'pot-worlds-'));
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const renderToken = 'test-render';
  const prs = await startRenderService({ port: 0, token: renderToken });
  let first;
  let second;
  let peerA;
  let peerB;
  t.after(async () => {
    peerA?.terminate();
    peerB?.terminate();
    await Promise.all([first?.close(), second?.close(), prs.close()]);
  });

  const readToken = 'test-reader';
  const writeToken = 'test-writer';
  const options = { readToken, writeToken, dataDir, renderEndpoint: prs.url, renderToken };
  first = await startWorldService(options);
  second = await startWorldService(options);
  const studio = new WorldApi(first.url, { readToken, writeToken });
  const player = new WorldApi(second.url, { readToken });
  await assert.rejects(() => new WorldApi(second.url).list(), /denied access/u);

  await player.health();
  assert.equal((await player.list()).length, starterWorlds.length);
  const scene = createScene('Integration world');
  await studio.publish(scene);
  assert.deepEqual(await player.load(scene.id), scene);
  assert.ok((await player.list()).some((entry) => entry.id === scene.id));
  await assert.rejects(() => player.publish({ ...scene, name: 'Unapproved' }), /denied access/u);

  const image = (await player.thumbnail(scene.id)).split(',')[1];
  const png = Buffer.from(image, 'base64');
  assert.equal(png.readUInt32BE(0), 0x89504e47);
  assert.equal(png.readUInt32BE(16), 480);
  assert.equal(png.readUInt32BE(20), 270);

  peerA = player.connect(scene.id);
  const nextA = watch(peerA);
  const a = await nextA(({ type }) => type === 'welcome');
  peerB = player.connect(scene.id);
  const nextB = watch(peerB);
  const b = await nextB(({ type }) => type === 'welcome');
  assert.notEqual(a.id, b.id);
  await nextA((message) => message.type === 'state' && message.players.length === 2);
  peerA.send(JSON.stringify({ type: 'move', ...scene.spawn, x: 0.25, yaw: 1 }));
  await nextB((message) => message.type === 'state' &&
    message.players.some((player) => player.id === a.id && player.x === 0.25));
  const closed = once(peerA, 'close');
  peerA.close();
  await closed;
  await nextB((message) => message.type === 'state' &&
    message.players.length === 1 && message.players[0].id === b.id);
});

test('desktop endpoint validation restricts production URLs and preserves base paths', () => {
  assert.throws(() => new WorldApi('http://sample.invalid/'), /HTTPS/u);
  assert.throws(() => new WorldApi('https://secret@sample.invalid/'), /credentials/u);
  assert.equal(new WorldApi('https://sample.invalid/pot').base.href, 'https://sample.invalid/pot/');
  assert.equal(new WorldApi('http://127.0.0.1:9000').base.protocol, 'http:');
});
