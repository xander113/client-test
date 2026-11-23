import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { decode, encode } from '@msgpack/msgpack';

const frameLimit = 2 * 1024 * 1024;

export class Runtime {
  #child;
  #incoming = Buffer.alloc(0);
  #next = 1;
  #requests = new Map();
  #closed = false;
  #onEvent;

  constructor(binary, dataDir, onEvent) {
    this.#onEvent = onEvent;
    this.#child = spawn(binary, ['desktop'], {
      env: { ...process.env, POT_LOCAL_DATA_DIR: dataDir },
      windowsHide: true,
      stdio: ['pipe', 'pipe', 'inherit'],
    });
    this.#child.stdout.on('data', (chunk) => this.#consume(chunk));
    this.#child.stdin.on('error', () => this.#fail());
    this.#child.on('error', () => this.#fail());
    this.#child.on('exit', () => this.#fail());
  }

  #fail() {
    this.#closed = true;
    for (const request of this.#requests.values()) request.reject(new Error('The Pot runtime closed.'));
    this.#requests.clear();
  }

  #consume(chunk) {
    this.#incoming = this.#incoming.length ? Buffer.concat([this.#incoming, chunk]) : chunk;
    try {
      while (this.#incoming.length >= 4) {
        const size = this.#incoming.readUInt32BE();
        if (!size || size > frameLimit) throw new Error('Invalid runtime frame size.');
        if (this.#incoming.length < size + 4) return;
        const packet = decode(this.#incoming.subarray(4, size + 4));
        this.#incoming = this.#incoming.subarray(size + 4);
        if (packet.event) {
          this.#onEvent(packet.window, packet.event);
          continue;
        }
        const request = this.#requests.get(packet.id);
        if (!request) continue;
        this.#requests.delete(packet.id);
        if (packet.error) request.reject(new Error(packet.error));
        else request.resolve(packet.value);
      }
    } catch (error) {
      console.error(error.message);
      this.#fail();
      this.#child.kill();
    }
  }

  #send(message) {
    if (this.#closed) throw new Error('The Pot runtime is unavailable.');
    const data = encode(message);
    if (data.length > frameLimit) throw new Error('The Pot request is too large.');
    const frame = Buffer.allocUnsafe(data.length + 4);
    frame.writeUInt32BE(data.length);
    frame.set(data, 4);
    this.#child.stdin.write(frame);
  }

  call(action, window, fields = {}) {
    const id = this.#next++;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.#requests.delete(id);
        reject(new Error('The Pot runtime took too long to respond.'));
      }, 12000);
      this.#requests.set(id, {
        resolve(value) {
          clearTimeout(timeout);
          resolve(value);
        },
        reject(error) {
          clearTimeout(timeout);
          reject(error);
        },
      });
      try {
        this.#send({ id, action, window, ...fields });
      } catch (error) {
        this.#requests.get(id).reject(error);
        this.#requests.delete(id);
      }
    });
  }

  input(window, input) {
    if (!this.#closed && !this.#child.stdin.writableNeedDrain) this.#send({ action: 'input', window, input });
  }

  close() {
    if (this.#child.exitCode !== null || this.#child.signalCode !== null || !this.#child.pid) return Promise.resolve();
    const done = once(this.#child, 'exit').catch(() => {});
    const deadline = setTimeout(() => this.#child.kill(), 3500);
    this.#child.stdin.end();
    return done.finally(() => clearTimeout(deadline));
  }
}
