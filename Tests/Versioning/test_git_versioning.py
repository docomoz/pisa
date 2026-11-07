import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]

class GitVersioningTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = pathlib.Path(self.temp.name)
        self.git('init', '-q', '-b', 'master')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        (self.repo / 'Resources').mkdir()
        (self.repo / 'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.4.5', 'CFBundleVersion': '45'}))
        (self.repo / 'file').write_text('first')
        shutil.copy(ROOT / '.gitattributes', self.repo / '.gitattributes')
        self.git('add', '.')
        self.git('commit', '-qm', 'initial')
        shutil.copytree(ROOT / 'scripts/versioning', self.repo / 'scripts/versioning')
        subprocess.run(['python3', str(self.repo / 'scripts/versioning/install.py')], cwd=self.repo, check=True, capture_output=True)

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.repo, check=True, capture_output=True, text=True).stdout.strip()

    def version(self, rev='HEAD'):
        data = subprocess.run(['git', 'show', f'{rev}:Resources/Info.plist'], cwd=self.repo, check=True, capture_output=True).stdout
        p = plistlib.loads(data)
        return p['CFBundleShortVersionString'], p['CFBundleVersion']

    def test_every_commit_advances_both(self):
        for patch in (6, 7):
            (self.repo / 'file').write_text(str(patch))
            self.git('add', 'file')
            self.git('commit', '-qm', 'change')
            self.assertEqual(self.version(), (f'0.4.{patch}', str(40 + patch)))
            self.assertEqual(plistlib.loads((self.repo / 'Resources/Info.plist').read_bytes())['CFBundleVersion'], str(40 + patch))

    def test_parallel_branch_uses_next_known_number(self):
        self.git('branch', 'other')
        (self.repo / 'file').write_text('branch one')
        self.git('add', 'file')
        self.git('commit', '-qm', 'branch one')
        self.git('checkout', '-q', 'other')
        (self.repo / 'file').write_text('branch two')
        self.git('add', 'file')
        self.git('commit', '-qm', 'branch two')
        self.assertEqual(self.version(), ('0.4.7', '47'))

    def test_automatic_merge_advances_version(self):
        self.git('checkout', '-qb', 'feature')
        (self.repo / 'feature').write_text('one')
        self.git('add', 'feature')
        self.git('commit', '-qm', 'feature')
        self.git('checkout', '-q', 'master')
        (self.repo / 'main').write_text('two')
        self.git('add', 'main')
        self.git('commit', '-qm', 'main')
        result = subprocess.run(['git', 'merge', '--no-edit', 'feature'], cwd=self.repo, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('git merge --no-commit', result.stderr)
        self.git('commit', '-qm', 'merge')
        self.assertEqual(self.version(), ('0.4.8', '48'))

    def test_unstaged_plist_edits_survive(self):
        p = self.repo / 'Resources/Info.plist'
        data = plistlib.loads(p.read_bytes())
        data['CustomUnstaged'] = 'keep me'
        p.write_bytes(plistlib.dumps(data))
        (self.repo / 'file').write_text('change')
        self.git('add', 'file')
        self.git('commit', '-qm', 'change')
        self.assertEqual(self.version(), ('0.4.6', '46'))
        self.assertEqual(plistlib.loads(p.read_bytes())['CustomUnstaged'], 'keep me')
        self.assertNotIn('CustomUnstaged', plistlib.loads(subprocess.run(['git', 'show', 'HEAD:Resources/Info.plist'], cwd=self.repo, check=True, capture_output=True).stdout))

if __name__ == '__main__':
    unittest.main()
