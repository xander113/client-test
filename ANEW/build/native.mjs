import { spawnSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const project = fileURLToPath(new URL('../', import.meta.url));
const architectures = { x64: 'amd64', arm64: 'arm64' };
const platforms = { win32: 'windows', darwin: 'darwin', linux: 'linux' };

export function executable(platform) {
  return platform === 'win32' ? 'potd.exe' : 'potd';
}

export function buildNative(platform = process.platform, arch = process.arch, destination) {
  if (!platforms[platform] || !architectures[arch]) {
    throw new Error(`Unsupported Pot target ${platform} ${arch}`);
  }
  const output = destination ?? join(project, '.native', `${platform}-${arch}`, executable(platform));
  mkdirSync(dirname(output), { recursive: true });
  const result = spawnSync(process.env.POT_GO_BIN || 'go', [
    'build', '-trimpath', '-ldflags=-s -w', '-o', output, './cmd/potd',
  ], {
    cwd: join(project, 'native'),
    stdio: 'inherit',
    env: { ...process.env, GOOS: platforms[platform], GOARCH: architectures[arch], CGO_ENABLED: '0' },
  });
  if (result.error?.code === 'ENOENT') throw new Error('Install Go 1.23 or newer and add it to PATH.');
  if (result.error || result.status !== 0) throw new Error('The Go runtime build failed.');
  return output;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  buildNative();
}
