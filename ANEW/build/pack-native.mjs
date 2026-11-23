import { Arch } from 'electron-builder';
import { join } from 'node:path';
import { buildNative, executable } from './native.mjs';

export default function packNative(context) {
  const platform = context.electronPlatformName;
  const resources = platform === 'darwin'
    ? join(context.appOutDir, `${context.packager.appInfo.productFilename}.app`, 'Contents', 'Resources')
    : join(context.appOutDir, 'resources');
  buildNative(platform, Arch[context.arch], join(resources, executable(platform)));
}
