import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import worker from '../dist/server/index.js';
import { measurementIdFromConfig } from '../scripts/analytics-config.mjs';

const request = (path, method = 'GET') => new Request(`https://pisa.example${path}`, { method });
test('the built Worker serves the page and its assets', async () => {
  const page = await worker.fetch(request('/'), {}, {});
  assert.equal(page.status, 200);
  assert.match(await page.text(), /Pisa пишет/);
  const css = await worker.fetch(request('/style.css'), {}, {});
  assert.match(css.headers.get('content-type'), /text\/css/);
  assert.match(await css.text(), /hero-logo/);
  const image = await worker.fetch(request('/assets/meeting.png'), {}, {});
  assert.equal(image.headers.get('content-type'), 'image/png');
  assert.deepEqual([...new Uint8Array(await image.arrayBuffer()).slice(0, 8)], [137,80,78,71,13,10,26,10]);
  const favicon = await worker.fetch(request('/assets/favicon.svg'), {}, {});
  assert.equal(favicon.status, 200);
  assert.match(favicon.headers.get('content-type'), /image\/svg\+xml/);
  const headerMark = await worker.fetch(request('/assets/mark-header.svg'), {}, {});
  assert.equal(headerMark.status, 200);
  assert.match(headerMark.headers.get('content-type'), /image\/svg\+xml/);
  const head = await worker.fetch(request('/', 'HEAD'), {}, {});
  assert.equal(head.status, 200);
  assert.equal((await head.arrayBuffer()).byteLength, 0);
});
test('the built Worker redirects to the latest feed DMG', async () => {
  const original = globalThis.fetch;
  const url = 'https://github.com/docomoz/pisa/releases/download/v9.8.7/Pisa-9.8.7-arm64.dmg';
  globalThis.fetch = async () => new Response(`<rss><item><enclosure url="${url}" /></item></rss>`);
  try {
    const response = await worker.fetch(request('/download'), {}, {});
    assert.equal(response.status, 302);
    assert.equal(response.headers.get('location'), url);
  } finally { globalThis.fetch = original; }
});
test('download buttons lead to the installation steps, where the DMG is available', async () => {
  const page = await (await worker.fetch(request('/'), {}, {})).text();
  assert.equal((page.match(/href="#install-guide"/g) || []).length, 3);
  assert.match(page, /id="install-guide"/);
  assert.match(page, /href="\/download">Скачайте DMG<\/a>/);
  assert.match(page, /xattr -dr com\.apple\.quarantine/);
});
test('the built page uses the configured measurement ID', async () => {
  const config = JSON.parse(await readFile(new URL('../analytics.json', import.meta.url), 'utf8'));
  const id = measurementIdFromConfig(config);
  const page = await (await worker.fetch(request('/'), {}, {})).text();
  const meta = page.match(/<meta name="pisa-ga-measurement-id" content="([^"]+)">/);
  assert.equal(meta?.[1] ?? '', id);
});

test('migration guide serves the verified source and destination paths', async () => {
  const response = await worker.fetch(request('/migration'));
  assert.equal(response.status, 200);
  const page = await response.text();
  assert.match(page, /com\.docomoz\.pisya/);
  assert.match(page, /com\.domocoz\.pisa/);
  assert.match(page, /Pisa-before-migration/);
});
