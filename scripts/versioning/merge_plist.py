#!/usr/bin/env python3
"""Merge plist properties, leaving version selection to the commit hook."""
import plistlib
import sys
from pathlib import Path

base, ours, theirs = (Path(p) for p in sys.argv[1:4])
try:
    a, b, c = (plistlib.loads(p.read_bytes()) for p in (base, ours, theirs))
    missing = object()
    out = {}
    for key in dict.fromkeys([*a, *b, *c]):
        old, left, right = (d.get(key, missing) for d in (a, b, c))
        if key in ('CFBundleShortVersionString', 'CFBundleVersion'):
            value = left
        elif left == right or right == old:
            value = left
        elif left == old:
            value = right
        else:
            print(f'Conflicting plist property: {key}', file=sys.stderr)
            sys.exit(1)
        if value is not missing:
            out[key] = value
    ours.write_bytes(plistlib.dumps(out, sort_keys=False))
except (OSError, ValueError, plistlib.InvalidFileException) as exc:
    print(f'Could not merge plist: {exc}', file=sys.stderr)
    sys.exit(1)
