#!/usr/bin/env python3
"""Install verified public model files. Run outside the offline application."""
import hashlib, json, pathlib, sys, urllib.request, os
def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): value.update(chunk)
    return value.hexdigest()

root = pathlib.Path.home() / 'Library/Containers/com.docomoz.pisya/Data/Library/Application Support/Pisya/Models'
manifest = json.loads((pathlib.Path(__file__).parent / 'models.json').read_text())
for item in manifest:
    destination = root / item['path']
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and digest(destination) == item['sha256']:
        print('Ready:', item['path']); continue
    partial = destination.with_name(destination.name + '.download')
    print('Downloading:', item['path'], flush=True)
    try:
        with urllib.request.urlopen(item['url'], timeout=120) as response, partial.open('wb') as output:
            while chunk := response.read(1024 * 1024): output.write(chunk)
        if digest(partial) != item['sha256']:
            raise RuntimeError('Checksum mismatch: ' + item['path'])
        os.replace(partial, destination)
    except Exception:
        partial.unlink(missing_ok=True); raise
print('Models installed. Restart Pisya.')
