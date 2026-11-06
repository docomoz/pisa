import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker, { downloadFromAppcast, handleRequest } from '../worker/index.js';

const dmg = 'https://github.com/docomoz/pisya/releases/download/v1.2.3/Pisya-1.2.3-arm64.dmg';
const feed = url => `<rss><channel><item><enclosure url="${url}" /></item></channel></rss>`;
test('redirects to the current DMG from the update feed without GitHub API', async () => {
  const result = await handleRequest(new Request('https://pisya.example/download'), async url => {
    assert.equal(url, 'https://github.com/docomoz/pisya/releases/latest/download/appcast.xml');
    return new Response(feed(dmg));
  });
  assert.equal(result.status, 302);
  assert.equal(result.headers.get('location'), dmg);
  assert.equal(result.headers.get('cache-control'), 'no-store');
});
test('rejects untrusted or mismatched URLs instead of redirecting', () => {
  for (const url of ['https://example.com/Pisya-1.2.3-arm64.dmg', 'https://github.com/docomoz/pisya/releases/download/v1.2.3/Pisya-1.2.2-arm64.dmg', 'https://github.com/docomoz/pisya/releases/download/v1.2.3/Pisya-1.2.3-arm64.dmg?next=bad']) assert.equal(downloadFromAppcast(feed(url)), null);
});
test('shows an error when the feed is unavailable instead of downloading an old version', async () => {
  const result = await handleRequest(new Request('https://pisya.example/download'), async () => new Response('', { status: 403 }));
  assert.equal(result.status, 503);
  assert.match(await result.text(), /странице последнего релиза/);
});

test('works when the hosting runtime supplies environment and context', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => new Response(feed(dmg));
  try {
    const result = await worker.fetch(new Request('https://pisya.example/download'), {}, {});
    assert.equal(result.status, 302);
    assert.equal(result.headers.get('location'), dmg);
  } finally {
    globalThis.fetch = original;
  }
});
