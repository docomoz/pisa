import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('legacy domains redirect to the canonical site with path and query preserved', async () => {
  const config = await readFile(new URL('../deploy/Caddyfile', import.meta.url), 'utf8');
  const block = config.match(/([^{}]+)\{\s*redir\s+https:\/\/getpisa\.app\{uri\}\s+permanent\s*\}/)?.[1];
  assert.ok(block, 'redirect must retain the full request URI');
  const hosts = block.split(',').map(host => host.trim());
  assert.ok(hosts.includes('pisya.app'));
  assert.ok(hosts.includes('www.pisya.app'));
});
