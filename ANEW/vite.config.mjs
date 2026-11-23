import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';

const fromProject = (path) => fileURLToPath(new URL(path, import.meta.url));

export default defineConfig({
  root: fromProject('renderer/'),
  base: './',
  build: {
    outDir: fromProject('dist/'),
    emptyOutDir: true,
    rolldownOptions: {
      input: {
        client: fromProject('renderer/client/index.html'),
        studio: fromProject('renderer/studio/index.html'),
      },
    },
  },
});
