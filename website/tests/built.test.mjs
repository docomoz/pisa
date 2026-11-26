import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import worker, { resetReleaseCache } from '../dist/server/index.js';
import { measurementIdFromConfig } from '../scripts/analytics-config.mjs';

const request = (path, method = 'GET') => new Request(`https://pisa.example${path}`, { method });
const badge = page => page.match(/<span class="pill-badge" data-release-version>([^<]*)<\/span>/)?.[1];
const releaseDate = page => page.match(/<span class="pill-date" data-release-date><time datetime="([^"]+)">([^<]+)<\/time><\/span>/)?.slice(1);

test('the release badge shows the latest version and keeps it between page loads', async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return new Response('<rss><item><pubDate>Tue, 03 Mar 2020 23:30:00 +0300</pubDate><enclosure url="https://github.com/docomoz/pisa/releases/download/v9.8.7/Pisa-9.8.7-arm64.dmg" /></item></rss>');
  };
  try {
    resetReleaseCache();
    const page = await (await worker.fetch(request('/'))).text();
    assert.equal(badge(page), 'v9.8.7');
    assert.deepEqual(releaseDate(page), ['2020-03-03', '3 марта 2020']);
    assert.equal(badge(await (await worker.fetch(request('/index.html'))).text()), 'v9.8.7');
    assert.equal(calls, 1);
  } finally { globalThis.fetch = original; }
});
test('the release badge falls back to a static label when the feed is unavailable', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => new Response('', { status: 503 });
  try {
    resetReleaseCache();
    const response = await worker.fetch(request('/'));
    assert.equal(response.status, 200);
    const page = await response.text();
    assert.equal(badge(page), 'Релиз');
    assert.match(page, /<span class="pill-date" data-release-date hidden><\/span>/);
  } finally { globalThis.fetch = original; }
});
test('the built Worker serves the page and its assets', async () => {
  const page = await worker.fetch(request('/'), {}, {});
  assert.equal(page.status, 200);
  assert.match(await page.text(), /<h1 id="hero-title">Вы разговариваете\.<br>Pisa записывает\.<\/h1>/);
  const css = await worker.fetch(request('/style.css'), {}, {});
  assert.match(css.headers.get('content-type'), /text\/css/);
  assert.match(await css.text(), /\.hero-product/);
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

test('feature screenshots load from the same assets as their full-size links', async () => {
  const page = await (await worker.fetch(request('/'))).text();
  for (const filename of ['speaker-labeling.png', 'term-labeling.png']) {
    const path = `assets/${filename}`;
    assert.ok(page.includes(`href="${path}"`));
    assert.ok(page.includes(`src="${path}"`));

    const image = await worker.fetch(request(`/${path}`));
    assert.equal(image.status, 200);
    assert.equal(image.headers.get('content-type'), 'image/png');
    assert.deepEqual([...new Uint8Array(await image.arrayBuffer()).slice(0, 8)], [137,80,78,71,13,10,26,10]);
  }
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
  assert.match(page, /href="\/download">Скачать DMG\b/u);
  assert.match(page, /xattr -dr com\.apple\.quarantine/);
  assert.match(page, /brew install --cask docomoz\/tap\/pisa\nxattr -dr com\.apple\.quarantine/);
});
test('the built page uses the configured measurement ID', async () => {
  const config = JSON.parse(await readFile(new URL('../analytics.json', import.meta.url), 'utf8'));
  const id = measurementIdFromConfig(config);
  const page = await (await worker.fetch(request('/'), {}, {})).text();
  const meta = page.match(/<meta name="pisa-ga-measurement-id" content="([^"]+)">/);
  assert.equal(meta?.[1] ?? '', id);
});

test('legacy migration links lead to the guide for both old app identifiers', async () => {
  for (const path of ['/migration', '/migration.html']) {
    for (const method of ['GET', 'HEAD']) {
      const response = await worker.fetch(request(path, method));
      assert.equal(response.status, 302);
      assert.equal(response.headers.get('location'), 'https://github.com/docomoz/pisa/blob/main/docs/migration.md');
    }
  }
  const guide = await readFile(new URL('../../docs/migration.md', import.meta.url), 'utf8');
  assert.match(guide, /com\.docomoz\.pisya/);
  assert.match(guide, /com\.domocoz\.pisa/);
  assert.match(guide, /com\.docomoz\.pisa/);
});
