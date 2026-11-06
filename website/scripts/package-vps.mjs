import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
if (process.argv.length !== 3) {
  console.error('Usage: node scripts/package-vps.mjs /absolute/path/pisya-site.tar.gz');
  process.exit(1);
}
const archive = resolve(process.argv[2]);
for (const [command, args] of [
  [process.execPath, ['scripts/build.mjs']],
  ['tar', ['-czf', archive, 'package.json', 'scripts/serve.mjs', 'dist/server/index.js', 'deploy/pisya-site.service', 'deploy/Caddyfile', 'deploy/install.sh', 'deploy/README.md']],
]) {
  const result = spawnSync(command, args, { cwd: root, stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
console.log(`Created ${archive}`);
