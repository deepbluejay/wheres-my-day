#!/usr/bin/env python3
"""Exercise the real wrapper in a disposable tree with invented tool responses."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
LANGUAGES = ('en', 'ko', 'ja', 'zh-Hans', 'zh-Hant', 'de', 'fr', 'es', 'ru')
DISPATCH = r'''#!/usr/bin/python3
import json
import os
from pathlib import Path
import shutil
import sys
import time

root = Path(os.environ['FIXTURE_ROOT'])
tool, args = Path(sys.argv[0]).name, sys.argv[1:]
with (root / 'events').open('a') as events:
    events.write(json.dumps([tool, *args]) + '\n')
failure = os.environ.get('FAILURE', '')
if tool == 'swift' and args == ['package', 'resolve']:
    if failure == 'resolve': sys.exit(46)
elif tool == 'swift':
    if os.environ.get('PAUSE_BUILD') and '--product' in args and args[-1] == 'ActivityProbe':
        (root / 'paused').touch()
        while not (root / 'resume').exists(): time.sleep(0.02)
    if '--show-bin-path' in args:
        if failure == 'bin-path': sys.exit(43)
        print(root / 'products')
    else:
        product = args[args.index('--product') + 1]
        if failure == product: sys.exit(41)
        directory = root / 'products'
        directory.mkdir(exist_ok=True)
        if failure != 'missing-helper' or product != 'ActivityQueryServer':
            path = directory / product
            if os.environ.get('NATIVE_PRODUCT'):
                shutil.copy2(os.environ['NATIVE_PRODUCT'], path)
            else:
                path.write_text('#!/bin/sh\nprintf executed > "$FIXTURE_ROOT/ran"\n')
            path.chmod(0o755)
elif tool == 'python3':
    if failure == 'strings': sys.exit(44)
    for language in ('en', 'ko', 'ja', 'zh-Hans', 'zh-Hant', 'de', 'fr', 'es', 'ru'):
        if failure == 'missing-language' and language == 'ru': continue
        directory = Path(args[-1]) / (language + '.lproj')
        directory.mkdir(parents=True)
        (directory / 'Localizable.strings').write_text('invented translation')
elif tool == 'codesign':
    if os.environ.get('NATIVE_PRODUCT'):
        os.execv('/usr/bin/codesign', ['codesign', *args])
    phase = 'verify' if '--verify' in args else 'sign'
    target = 'helper' if Path(args[-1]).name == 'ActivityQueryServer' else 'app'
    if failure == phase + '-' + target: sys.exit(45)
elif tool == 'open':
    (root / 'opened').touch()
else:
    sys.exit(99)
'''


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=os.environ.get('ACTIVITYPROBE_TEST_ROOT'))
        self.root = Path(self.temporary.name)
        shutil.copy2(ROOT / 'probe.sh', self.root)
        shutil.copy2(ROOT / 'Info.plist', self.root)
        self.bin = self.root / 'fake-bin'
        self.bin.mkdir()
        dispatcher = self.bin / 'dispatch'
        dispatcher.write_text(DISPATCH)
        dispatcher.chmod(0o755)
        for name in ('swift', 'python3', 'codesign', 'open', 'security'):
            (self.bin / name).symlink_to(dispatcher)
        self.app = self.root / 'build/ActivityProbe.app'
        self.environment = dict(PATH=str(self.bin) + ':/usr/bin:/bin', FIXTURE_ROOT=str(self.root))

    def tearDown(self):
        self.temporary.cleanup()

    def seed_stale_bundle(self):
        executable = self.app / 'Contents/MacOS/ActivityProbe'
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text('#!/bin/sh\nprintf stale > "$FIXTURE_ROOT/ran"\n')
        executable.chmod(0o755)
        (self.app / 'obsolete-file').touch()

    def run_wrapper(self, *arguments, failure='', identity=None):
        environment = dict(self.environment, FAILURE=failure)
        if identity is not None:
            environment['SIGNING_IDENTITY'] = identity
        return subprocess.run(['/bin/bash', str(self.root / 'probe.sh'), *arguments],
                              env=environment, capture_output=True, text=True, timeout=30)

    def events(self):
        path = self.root / 'events'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_no_bundle_or_launch(self):
        self.assertFalse(self.app.exists())
        self.assertFalse((self.root / 'ran').exists())
        self.assertFalse((self.root / 'opened').exists())
        self.assertEqual(list((self.root / 'build').glob('.bundle.*')), [])

    # Ideal: a later refused or failed build recovers even a signed, abandoned stage.
    def test_abandoned_signed_stage_is_removed_before_refused_and_failed_builds(self):
        product = self.root / 'invented-product'
        compiled = subprocess.run(['/usr/bin/clang', '-x', 'c', '-', '-o', str(product)],
                                  input='int main(void) { return 0; }\n', text=True,
                                  capture_output=True, timeout=30)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        self.environment['NATIVE_PRODUCT'] = str(product)
        for failure in ('identity', 'ActivityProbe'):
            with self.subTest(failure=failure):
                self.assertEqual(self.run_wrapper('build', '--adhoc').returncode, 0)
                signed_stage = self.root / ('build/.bundle.' + failure)
                signed_stage.mkdir()
                shutil.move(self.app, signed_stage / self.app.name)
                verified = subprocess.run(['/usr/bin/codesign', '--verify', '--strict',
                                           str(signed_stage / self.app.name)], capture_output=True, timeout=30)
                self.assertEqual(verified.returncode, 0, verified.stderr)
                result = (self.run_wrapper('build') if failure == 'identity' else
                          self.run_wrapper('build', '--adhoc', failure=failure))
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_bundle_or_launch()

    def wait_for(self, predicate):
        deadline = time.monotonic() + 10
        while not predicate():
            if time.monotonic() >= deadline:
                self.fail('Timed out waiting for invented packaging process')
            time.sleep(0.02)

    # Ideal: recovery cannot remove a concurrent builder's active stage.
    def test_packaging_serializes_and_recovers_after_killed_builder(self):
        environment = dict(self.environment, PAUSE_BUILD='1')
        first = subprocess.Popen(['/bin/bash', str(self.root / 'probe.sh'), 'build', '--adhoc'],
                                 env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 start_new_session=True)
        second = None
        try:
            self.wait_for(lambda: (self.root / 'paused').exists())
            stage = next((self.root / 'build').glob('.bundle.*'))
            second = subprocess.Popen(['/bin/bash', str(self.root / 'probe.sh'), 'build'],
                                      env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      start_new_session=True)
            time.sleep(0.2)
            self.assertIsNone(second.poll(), 'Concurrent packaging must wait for the lock')
            self.assertTrue(stage.exists(), 'An active stage must survive another invocation')
            os.killpg(first.pid, signal.SIGKILL)
            first.communicate(timeout=10)
            second.communicate(timeout=10)
            self.assertEqual(second.returncode, 2)
            self.assert_no_bundle_or_launch()
        finally:
            for process in (first, second):
                if process is not None:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=10)

    # Ideal: every failure stops before invoking a command or retaining an executable bundle.
    def test_failed_build_copy_translation_signing_and_verification_remove_bundle(self):
        for failure in ('ActivityProbe', 'ActivityQueryServer', 'bin-path', 'missing-helper',
                        'strings', 'missing-language', 'sign-helper', 'sign-app', 'verify-helper', 'verify-app'):
            for command in ('build', 'start', 'status'):
                with self.subTest(failure=failure, command=command):
                    shutil.rmtree(self.root / 'products', ignore_errors=True)
                    self.seed_stale_bundle()
                    result = self.run_wrapper(command, '--adhoc', failure=failure)
                    self.assertNotEqual(result.returncode, 0)
                    self.assert_no_bundle_or_launch()

    # Ideal: a dependency that cannot be resolved stops before the bundle is touched, and nothing launches.
    def test_failed_resolve_keeps_previous_bundle_and_launches_nothing(self):
        for command in ('build', 'start', 'status'):
            with self.subTest(command=command):
                (self.root / 'events').unlink(missing_ok=True)
                self.seed_stale_bundle()
                (self.root / 'build/.bundle.abandoned').mkdir()
                result = self.run_wrapper(command, '--adhoc', failure='resolve')
                self.assertEqual(result.returncode, 46)
                self.assertEqual(self.events(), [['swift', 'package', 'resolve']])
                self.assertTrue((self.app / 'obsolete-file').exists())
                self.assertFalse((self.root / 'ran').exists())
                self.assertFalse((self.root / 'opened').exists())
                self.assertEqual(list((self.root / 'build').glob('.bundle.*')), [])

    def test_missing_identity_and_implicit_adhoc_are_refused_before_tools(self):
        for identity in (None, '', '-'):
            with self.subTest(identity=identity):
                self.seed_stale_bundle()
                self.assertEqual(self.run_wrapper('build', identity=identity).returncode, 2)
                self.assertEqual(self.events(), [])
                self.assert_no_bundle_or_launch()

    # Ideal: only fresh payloads ship; the helper is signed before the bundle with one identity.
    def test_fresh_bundle_contents_and_signature_order(self):
        self.seed_stale_bundle()
        result = self.run_wrapper('--adhoc', 'build')
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = {'Contents/Info.plist', 'Contents/MacOS/ActivityProbe',
                    'Contents/MacOS/ActivityQueryServer'}
        expected.update('Contents/Resources/' + language + '.lproj/Localizable.strings'
                        for language in LANGUAGES)
        self.assertEqual({str(path.relative_to(self.app)) for path in self.app.rglob('*') if path.is_file()}, expected)
        calls = self.events()
        builds = [call for call in calls if call[0] == 'swift']
        self.assertEqual(builds, [['swift', 'package', 'resolve'],
                                 ['swift', 'build', '--jobs', '1', '--product', 'ActivityProbe'],
                                 ['swift', 'build', '--jobs', '1', '--product', 'ActivityQueryServer'],
                                 ['swift', 'build', '--jobs', '1', '--show-bin-path']])
        signs = [call for call in calls if call[0] == 'codesign']
        self.assertEqual([call[1:-1] for call in signs],
                         [['--force', '--sign', '-'], ['--force', '--sign', '-'],
                          ['--verify', '--strict'], ['--verify', '--strict']])
        self.assertEqual([Path(call[-1]).name for call in signs],
                         ['ActivityQueryServer', 'ActivityProbe.app', 'ActivityQueryServer', 'ActivityProbe.app'])
        self.assertFalse((self.root / 'ran').exists())

    def test_explicit_identity_is_passed_without_discovery(self):
        result = self.run_wrapper('build', identity='Invented signing identity')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(call[0] in ('swift', 'python3', 'codesign') for call in self.events()))
        signs = [call for call in self.events() if call[0] == 'codesign' and '--sign' in call]
        self.assertEqual([call[3] for call in signs], ['Invented signing identity'] * 2)



if __name__ == '__main__':
    unittest.main()
