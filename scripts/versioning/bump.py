#!/usr/bin/env python3
"""Advance the version in the index without staging other worktree changes."""
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

FILE = 'Resources/Info.plist'

def git(*args, input=None, check=True):
    return subprocess.run(['git', *args], input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check).stdout

def numbers(data):
    info = plistlib.loads(data)
    version = str(info['CFBundleShortVersionString'])
    match = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)', version)
    build = str(info['CFBundleVersion'])
    if not match or not re.fullmatch(r'\d+', build):
        raise ValueError('Version must be major.minor.patch and build must be an integer')
    return tuple(map(int, match.groups())), int(build)

def replace(data, version, build):
    # Preserve formatting and every unrelated property, including unstaged edits.
    for key, value in [('CFBundleShortVersionString', version), ('CFBundleVersion', build)]:
        pattern = rb'(<key>\s*' + key.encode() + rb'\s*</key>\s*<string>)[^<]*(</string>)'
        data, count = re.subn(pattern, lambda m: m[1] + value.encode() + m[2], data, count=1)
        if count != 1:
            raise ValueError(f'Could not update {key} in the XML plist')
    plistlib.loads(data)
    return data

def main():
    staged = git('show', ':' + FILE)
    versions = [numbers(staged)]
    refs = git('for-each-ref', '--format=%(refname)', 'refs/heads', 'refs/remotes', 'refs/tags').decode().splitlines()
    for ref in refs + ['HEAD']:
        result = subprocess.run(['git', 'show', f'{ref}:{FILE}'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if result.returncode == 0:
            try:
                versions.append(numbers(result.stdout))
            except (ValueError, KeyError, plistlib.InvalidFileException):
                continue
    version = max(v for v, _ in versions)
    build = max(b for _, b in versions) + 1
    new_version = f'{version[0]}.{version[1]}.{version[2] + 1}'
    new_index = replace(staged, new_version, str(build))
    path = Path(FILE)
    worktree = path.read_bytes()
    new_worktree = replace(worktree, new_version, str(build))
    obj = git('hash-object', '-w', '--stdin', input=new_index).decode().strip()
    git('update-index', '--cacheinfo', '100644', obj, FILE)
    path.write_bytes(new_worktree)
    print(f'Pisa version: {new_version} ({build})', file=sys.stderr)

if __name__ == '__main__':
    try:
        main()
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError, plistlib.InvalidFileException) as exc:
        print(f'Could not advance Pisa version: {exc}', file=sys.stderr)
        sys.exit(1)
