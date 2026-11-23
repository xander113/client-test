import { mkdir } from 'node:fs/promises';

await mkdir(new URL('../WEBSERVICE/', import.meta.url), { recursive: true });
