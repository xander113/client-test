import { randomUUID } from 'node:crypto';
import { WebSocket, WebSocketServer } from 'ws';
import { RequestError } from './http.mjs';

const maxSessions = 128;
const maxPlayersPerRoom = 24;
const maxBufferedBytes = 128 * 1024;
const maxMovementRate = 30;
const maxMovementSpeed = 35;
const colors = ['#09b734', '#206ae0', '#8058df', '#d77120', '#d14876', '#148f8f'];

function clamp(number, min, max) {
  return Math.max(min, Math.min(max, number));
}

function send(client, payload) {
  if (client.readyState !== WebSocket.OPEN) return;
  if (client.bufferedAmount > maxBufferedBytes) {
    client.close(1013, 'Connection too slow');
    return;
  }
  client.send(payload);
}

function updatePose(state, pose, now) {
  const player = state.player;
  const x = clamp(pose.x, -320, 320);
  const y = clamp(pose.y, -40, 330);
  const z = clamp(pose.z, -320, 320);
  const yaw = Math.atan2(Math.sin(pose.yaw), Math.cos(pose.yaw));
  const distance = Math.hypot(x - player.x, y - player.y, z - player.z);
  state.travelBudget = Math.min(12, state.travelBudget + (now - state.lastPoseAt) * maxMovementSpeed / 1000);
  state.lastPoseAt = now;
  if (distance > state.travelBudget && distance > 0) {
    // Catch up over subsequent updates after movement bursts or network jitter.
    const fraction = state.travelBudget / distance;
    player.x += fraction * (x - player.x);
    player.y += fraction * (y - player.y);
    player.z += fraction * (z - player.z);
    player.yaw = yaw;
    state.travelBudget = 0;
    return true;
  }

  if (distance === 0 && player.yaw === yaw) return false;
  state.travelBudget -= distance;
  Object.assign(player, { x, y, z, yaw });
  return true;
}

export function createRooms() {
  const server = new WebSocketServer({ noServer: true, maxPayload: 1024, perMessageDeflate: false });
  const rooms = new Map();

  const broadcast = setInterval(() => {
    for (const room of rooms.values()) {
      if (!room.dirty) continue;
      room.dirty = false;
      const players = Array.from(room.members.values(), (member) => member.player);
      const payload = JSON.stringify({ type: 'state', players });
      for (const client of room.members.keys()) send(client, payload);
    }
  }, 67);
  broadcast.unref();

  const heartbeat = setInterval(() => {
    for (const room of rooms.values()) {
      for (const [client, member] of room.members) {
        if (!member.alive) client.terminate();
        else if (client.readyState === WebSocket.OPEN) {
          member.alive = false;
          client.ping();
        }
      }
    }
  }, 20_000);
  heartbeat.unref();

  function disconnect(id) {
    const room = rooms.get(id);
    if (!room) return;
    rooms.delete(id);
    for (const client of room.members.keys()) client.close(1012, 'World updated');
  }

  function upgrade(request, socket, head, scene) {
    if (server.clients.size >= maxSessions) throw new RequestError(503, 'All play sessions are busy');
    const existing = rooms.get(scene.id);
    if (existing && existing.scene !== scene) disconnect(scene.id);
    if (rooms.get(scene.id)?.members.size >= maxPlayersPerRoom) {
      throw new RequestError(503, 'This play session is full');
    }

    server.handleUpgrade(request, socket, head, (client) => {
      let room = rooms.get(scene.id);
      if (!room) {
        room = { scene, members: new Map(), dirty: false };
        rooms.set(scene.id, room);
      }

      const id = randomUUID();
      const player = {
        id,
        name: `Guest ${id.slice(0, 4).toUpperCase()}`,
        color: colors[Number.parseInt(id.slice(0, 2), 16) % colors.length],
        ...scene.spawn,
        yaw: 0,
      };
      const now = performance.now();
      const member = { player, alive: true, travelBudget: 3, lastPoseAt: now, budgetAt: now, messages: maxMovementRate };
      room.members.set(client, member);
      room.dirty = true;
      client.on('error', () => client.terminate());
      client.on('pong', () => { member.alive = true; });
      client.on('close', () => {
        room.members.delete(client);
        room.dirty = true;
        if (!room.members.size && rooms.get(scene.id) === room) rooms.delete(scene.id);
      });
      client.on('message', (data, binary) => {
        const now = performance.now();
        member.messages = Math.min(maxMovementRate, member.messages + (now - member.budgetAt) * maxMovementRate / 1000);
        member.budgetAt = now;
        if (member.messages < 1) {
          client.close(1008, 'Too many updates');
          return;
        }
        member.messages -= 1;
        if (binary) {
          client.close(1003, 'Use JSON position updates');
          return;
        }

        let pose;
        try {
          pose = JSON.parse(data.toString());
        } catch {
          client.close(1007, 'Invalid JSON');
          return;
        }
        if (pose?.type !== 'move' || ![pose.x, pose.y, pose.z, pose.yaw].every(Number.isFinite)) {
          client.close(1008, 'Invalid position update');
          return;
        }
        if (updatePose(member, pose, now)) room.dirty = true;
      });
      send(client, JSON.stringify({ type: 'welcome', id }));
    });
  }

  return {
    upgrade,
    disconnect,
    close() {
      clearInterval(heartbeat);
      clearInterval(broadcast);
      return new Promise((resolve) => {
        const timer = setTimeout(() => {
          for (const client of server.clients) client.terminate();
        }, 500);
        timer.unref();
        server.close(() => {
          clearTimeout(timer);
          resolve();
        });
        for (const client of server.clients) client.close(1001, 'Service shutting down');
      });
    },
  };
}
