import { build } from 'vite';
import { build as buildDesktop, Platform } from 'electron-builder';

const platform = { win32: Platform.WINDOWS, darwin: Platform.MAC }[process.platform];
if (!platform) {
  console.error('Pot desktop packages are built on Windows or macOS.');
  process.exit(1);
}

const product = process.argv[2];
if (!['client', 'studio', 'all'].includes(product)) {
  console.error('Choose client, studio, or all.');
  process.exit(1);
}

await build();
for (const name of product === 'all' ? ['client', 'studio'] : [product]) {
  await buildDesktop({
    config: `build/${name}.yml`,
    targets: platform.createTarget(),
    publish: 'never',
  });
}
