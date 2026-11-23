import { spawn } from 'node:child_process';
import { buildNative } from './native.mjs';

const mode = process.argv[2];
if (mode !== 'worlds' && mode !== 'render') throw new Error('Choose worlds or render.');
const processHandle = spawn(buildNative(), [mode], { stdio: 'inherit' });
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => processHandle.kill(signal));
}
processHandle.once('exit', (code) => { process.exitCode = code ?? 0; });
processHandle.once('error', (error) => {
  console.error(error.message);
  process.exitCode = 1;
});
