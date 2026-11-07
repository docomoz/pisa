import { readFile, writeFile, mkdir, copyFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { measurementIdFromConfig } from './analytics-config.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const publicFiles = {
  '/index.html': 'text/html; charset=utf-8',
  '/style.css': 'text/css; charset=utf-8',
  '/script.js': 'application/javascript; charset=utf-8',
  '/analytics.js': 'application/javascript; charset=utf-8',
  '/assets/mark.svg': 'image/svg+xml',
  '/assets/mark-header.svg': 'image/svg+xml',
  '/assets/meeting.png': 'image/png',
  '/assets/welcome.png': 'image/png',
};
const assets = {};
const analyticsConfig = JSON.parse(await readFile(path.join(root, 'analytics.json'), 'utf8'));
const measurementId = measurementIdFromConfig(analyticsConfig);
for (const [name, type] of Object.entries(publicFiles)) {
  let data = await readFile(path.join(root, 'dist', name.slice(1)));
  if (name === '/index.html' && measurementId) {
    data = Buffer.from(data.toString('utf8').replace('</head>', `  <meta name="pisya-ga-measurement-id" content="${measurementId}">\n</head>`));
  }
  assets[name] = { type, data: data.toString('base64') };
}
const source = await readFile(path.join(root, 'worker/index.js'), 'utf8');
await mkdir(path.join(root, 'dist/server'), { recursive: true });
await mkdir(path.join(root, 'dist/.openai'), { recursive: true });
await writeFile(path.join(root, 'dist/server/index.js'), `const ASSETS = ${JSON.stringify(assets)};\n${source}`);
try {
  await copyFile(path.join(root, '.openai/hosting.json'), path.join(root, 'dist/.openai/hosting.json'));
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}
console.log(`Built Pisya website Worker (GA4: ${measurementId || 'disabled'})`);
