import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker, { downloadFromAppcast, versionFromAppcast, releaseDateFromAppcast, formatReleaseDate, handleRequest } from '../worker/index.js';

const dmg = 'https://github.com/docomoz/pisa/releases/download/v1.2.3/Pisa-1.2.3-arm64.dmg';
const feed = url => `<rss><channel><item><enclosure url="${url}" /></item></channel></rss>`;
test('redirects to the current DMG from the update feed without GitHub API', async () => {
  const result = await handleRequest(new Request('https://pisa.example/download'), async url => {
    assert.equal(url, 'https://github.com/docomoz/pisa/releases/latest/download/pisa-updates.xml');
    return new Response(feed(dmg));
  });
  assert.equal(result.status, 302);
  assert.equal(result.headers.get('location'), dmg);
  assert.equal(result.headers.get('cache-control'), 'no-store');
});
test('rejects untrusted or mismatched URLs instead of redirecting', () => {
  for (const url of ['https://example.com/Pisa-1.2.3-arm64.dmg', 'https://github.com/docomoz/pisa/releases/download/v1.2.3/Pisa-1.2.2-arm64.dmg', 'https://github.com/docomoz/pisa/releases/download/v1.2.3/Pisa-1.2.3-arm64.dmg?next=bad']) assert.equal(downloadFromAppcast(feed(url)), null);
});
test('shows an error when the feed is unavailable instead of downloading an old version', async () => {
  const result = await handleRequest(new Request('https://pisa.example/download'), async () => new Response('', { status: 403 }));
  assert.equal(result.status, 503);
  assert.match(await result.text(), /странице последнего релиза/);
});

test('works when the hosting runtime supplies environment and context', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => new Response(feed(dmg));
  try {
    const result = await worker.fetch(new Request('https://pisa.example/download'), {}, {});
    assert.equal(result.status, 302);
    assert.equal(result.headers.get('location'), dmg);
  } finally {
    globalThis.fetch = original;
  }
});

test('retries one stale latest redirect with a unique cache buster on 404', async () => {
  const retries = [];
  for (let i = 0; i < 2; i++) {
    const calls = [];
    const result = await handleRequest(new Request('https://pisa.example/download'), async (url, options) => {
      calls.push(url);
      assert.equal(options.cache, 'no-store');
      return calls.length === 1 ? new Response('', { status: 404 }) : new Response(feed(dmg));
    });
    assert.equal(result.status, 302);
    assert.equal(result.headers.get('location'), dmg);
    assert.equal(calls.length, 2);
    const retry = new URL(calls[1]);
    assert.equal(retry.origin + retry.pathname, calls[0]);
    retries.push(retry.searchParams.get('site_retry'));
  }
  assert.ok(retries[0]);
  assert.notEqual(retries[0], retries[1]);
});

test('a second 404 stops retrying and returns an error', async () => {
  let calls = 0;
  const result = await handleRequest(new Request('https://pisa.example/download'), async () => {
    calls++;
    return new Response('', { status: 404 });
  });
  assert.equal(calls, 2);
  assert.equal(result.status, 503);
});

test('reads the version only from a trusted DMG link', () => {
  assert.equal(versionFromAppcast(feed(dmg)), '1.2.3');
  assert.equal(versionFromAppcast(feed('https://example.com/v6.6.6/Pisa-6.6.6-arm64.dmg')), null);
  assert.equal(versionFromAppcast('<rss></rss>'), null);
});

test('formats the release date in Moscow time and omits the current year', () => {
  const late = releaseDateFromAppcast(`<rss><item><pubDate>Tue, 24 Nov 2026 23:30:00 +0000</pubDate><enclosure url="${dmg}" /></item></rss>`);
  assert.deepEqual(formatReleaseDate(late, new Date('2026-12-01T12:00:00Z')), { label: '25 ноября', iso: '2026-11-25' });
  assert.deepEqual(formatReleaseDate(late, new Date('2027-01-10T12:00:00Z')), { label: '25 ноября 2026', iso: '2026-11-25' });
  assert.equal(releaseDateFromAppcast(`<rss><item><pubDate>soon</pubDate><enclosure url="${dmg}" /></item></rss>`), null);
  assert.equal(releaseDateFromAppcast('<rss><item><pubDate>Tue, 24 Nov 2026 20:38:04 +0300</pubDate></item></rss>'), null);
});
