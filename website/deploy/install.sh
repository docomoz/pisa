#!/bin/sh
set -eu

# Run from an extracted package on the dedicated VPS as root.
if [ "$(id -u)" -ne 0 ]; then echo 'Run as root' >&2; exit 1; fi
command -v systemctl >/dev/null
command -v /usr/bin/node >/dev/null || { echo 'Install Node.js 22 or newer at /usr/bin/node' >&2; exit 1; }
/usr/bin/node -e 'if (+process.versions.node.split(".")[0] < 22) process.exit(1)' || { echo 'Node.js 22 or newer is required' >&2; exit 1; }
cd "$(dirname "$0")/.."
for file in package.json scripts/serve.mjs dist/server/index.js deploy/pisya-site.service; do
  [ -f "$file" ] || { echo "Missing $file" >&2; exit 1; }
done
unit=/etc/systemd/system/pisya-site.service
if [ -e "$unit" ] && ! grep -q '^# Managed by Pisya site deploy$' "$unit"; then
  echo "Refusing to overwrite $unit" >&2; exit 1
fi
base=/opt/pisya-site
if [ -e "$base/current" ] && [ ! -L "$base/current" ]; then
  echo "Refusing to overwrite $base/current" >&2; exit 1
fi
id pisya-site >/dev/null 2>&1 || useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin pisya-site
install -d -m 755 "$base/releases"
release=$(mktemp -d "$base/releases/release.XXXXXXXX")
chmod 755 "$release"
install -d -m 755 "$release/scripts" "$release/dist/server"
install -m 644 package.json "$release/package.json"
install -m 644 scripts/serve.mjs "$release/scripts/serve.mjs"
install -m 644 dist/server/index.js "$release/dist/server/index.js"
install -m 644 deploy/pisya-site.service "$unit"
ln -s "$release" "$base/current.new"
mv -Tf "$base/current.new" "$base/current"
systemctl daemon-reload
systemctl enable pisya-site.service
systemctl restart pisya-site.service
systemctl is-active --quiet pisya-site.service
echo 'Pisya site is running on 127.0.0.1:4173; configure Caddy separately.'
