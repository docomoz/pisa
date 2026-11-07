#!/usr/bin/env python3
"""Install shared Git hooks for all worktrees in this clone."""
import os
import shutil
import shlex
import subprocess
import sys
from pathlib import Path

root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip())
common = Path(subprocess.check_output(['git', 'rev-parse', '--git-common-dir'], text=True).strip())
if not common.is_absolute():
    common = (Path.cwd() / common).resolve()
custom = subprocess.run(['git', 'config', '--get', 'core.hooksPath'], capture_output=True, text=True)
if custom.returncode == 0:
    sys.exit('A custom core.hooksPath is already configured; integrate the version hook there manually.')
hooks = common / 'hooks'
hooks.mkdir(exist_ok=True)
marker = '# Pisya automatic version hook'
for name in ('pre-commit', 'pre-merge-commit'):
    target = hooks / name
    if target.exists() and marker not in target.read_text():
        sys.exit(f'Refusing to overwrite existing hook: {target}')
install_dir = common / 'pisya-versioning'
install_dir.mkdir(exist_ok=True)
for script in ('bump.py', 'merge_plist.py'):
    shutil.copy2(root / 'scripts/versioning' / script, install_dir / script)
driver = 'python3 ' + shlex.quote(str(install_dir / 'merge_plist.py')) + ' %O %A %B'
existing = subprocess.run(['git', 'config', '--get', 'merge.pisya-plist.driver'], capture_output=True, text=True)
if existing.returncode == 0 and existing.stdout.strip() != driver:
    sys.exit('A different pisya-plist merge driver is already configured.')
subprocess.run(['git', 'config', 'merge.pisya-plist.driver', driver], check=True)
for name in ('pre-commit', 'pre-merge-commit'):
    target = hooks / name

    if name == 'pre-merge-commit':
        target.write_text('#!/bin/sh\n' + marker + '\necho "Pisya: use git merge --no-commit, then git commit, so the version can advance." >&2\nexit 1\n')
    else:
        target.write_text('#!/bin/sh\n' + marker + '\nset -e\ncommon=$(git rev-parse --git-common-dir)\nexec python3 "$common/pisya-versioning/bump.py"\n')
    os.chmod(target, 0o755)
print('Pisya version hooks installed for this clone and its worktrees.')
