#!/usr/bin/env python3
"""Invented files only. Expected answers specify behavior before consulting the implementation."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'Sources/Shell/AgentCleanup/agent_cleanup.py'
spec = importlib.util.spec_from_file_location('agent_cleanup', SCRIPT)
cleanup = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = cleanup
spec.loader.exec_module(cleanup)

APP = '/invented/Old App.app/Contents/MacOS/ActivityProbe'
HOOK = '/invented/Old App.app/Contents/MacOS/ActivityProbeHook'
HASH = 'sha256:' + 'a' * 64
OTHER_HASH = 'sha256:' + 'b' * 64
KEY = 'invented.file:Stop:0:0'


def command(provider='codex'):
    return "'" + HOOK + "' " + provider


def group(provider='codex'):
    return {'hooks': [{'type': 'command', 'command': command(provider), 'timeout': 15}]}


class CleanupTest(unittest.TestCase):
    def setUp(self):
        base = Path('/tmp/ap-agent-cleanup-tests').resolve()
        base.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=base)
        self.home = Path(self.temp.name).resolve()
        self.own = cleanup.Ownership([APP], [HOOK])
        self.write('.claude/settings.json', '{ "hooks" : {}, "foreign" : "한글 🧭" }\n')
        self.write('.codex/hooks.json', '{ "hooks" : {}, "foreign" : 1e3 }\n')
        self.write('.codex/config.toml', '# untouched\nmodel = "invented"\n')
        self.write('registration.json', '{ "mcpServers" : {}, "other" : [1, 2] }\n')
        self.write('ledger.json', json.dumps({'codex-approved': [[KEY, HASH]]}))

    def tearDown(self):
        self.temp.cleanup()

    def write(self, path, text):
        target = self.home / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(text.encode('utf-8'))
        target.chmod(0o640)
        return target

    def options(self, apply=False):
        return cleanup.arguments((['--apply', '--live-switch'] if apply else ['--dry-run']) +
            ['--home', str(self.home), '--old-app', APP, '--old-hook', HOOK,
             '--claude-mcp-file', 'registration.json', '--metadata-file', 'ledger.json'])

    def tree(self):
        return {str(p.relative_to(self.home)): p.read_bytes() for p in self.home.rglob('*') if p.is_file()}

    def seed(self):
        mine = json.dumps(group('claude'))
        self.write('.claude/settings.json', '{\r\n "hooks":{"Stop":[' + mine + ', {"hooks":[]}]},\r\n "foreign":"한글 🧭"\r\n}\r\n')
        mine = json.dumps(group())
        foreign = '{ "hooks": [{"type":"command","command":"invented-other", "timeout":20}] }'
        self.codex_before = '{ "hooks" : { "Stop" : [ ' + mine + ' ,\n ' + foreign + ' , ' + mine + ' ] }, "keep":true }\n'
        self.codex_expected = '{ "hooks" : { "Stop" : [ {"hooks": []} ,\n ' + foreign + '  ] }, "keep":true }\n'
        self.write('.codex/hooks.json', self.codex_before)
        self.config_before = '# untouched\nmodel = "invented"\n[hooks.state."' + KEY + '"]\ntrusted_hash = "' + HASH + '" # keep comment\nenabled = false\n[hooks.state."foreign:1"]\ntrusted_hash = "' + OTHER_HASH + '"\n[mcp_servers.activityprobe]\ncommand = ' + json.dumps(APP) + '\nargs = ["mcp"]\n[mcp_servers.foreign]\ncommand = "invented-other"\nargs = ["mcp"]\n'
        self.config_expected = '# untouched\nmodel = "invented"\n[hooks.state."' + KEY + '"]\n # keep comment\nenabled = false\n[hooks.state."foreign:1"]\ntrusted_hash = "' + OTHER_HASH + '"\n\n\n\n[mcp_servers.foreign]\ncommand = "invented-other"\nargs = ["mcp"]\n'
        self.write('.codex/config.toml', self.config_before)
        server = json.dumps({'command': APP, 'args': ['mcp'], 'type': 'stdio'})
        self.write('registration.json', '{"mcpServers": {"activityprobe": ' + server + ', "foreign":{"command":"invented-other"}}, "keep":1}\n')

    def test_dry_run_counts_only_and_no_side_effects(self):
        # Ideal: three hooks, one trust and two registrations; no byte, mode or directory changes.
        self.seed()
        before = self.tree()
        status, report = cleanup.execute(self.options())
        self.assertEqual(status, 0, report)
        self.assertEqual(report['counts'], {'hooks': 3, 'placeholders': 1, 'trust': 1, 'mcp': 2,
            'preserved_trust_mismatches': 0, 'files_to_change': 4, 'files_changed': 0})
        self.assertEqual(self.tree(), before)
        self.assertFalse(list(self.home.glob('.activityprobe-cleanup-*')))

    def test_apply_exact_bytes_positions_private_backups_and_second_run(self):
        # Ideal: foreign bytes and group index 1 remain exactly the same; repeat writes nothing.
        self.seed()
        before = self.tree()
        status, report = cleanup.execute(self.options(True))
        self.assertEqual(status, 0, report)
        self.assertEqual((self.home / '.codex/hooks.json').read_text(), self.codex_expected)
        self.assertEqual((self.home / '.codex/config.toml').read_text(), self.config_expected)
        self.assertEqual((self.home / '.claude/settings.json').read_bytes(),
            '{\r\n "hooks":{"Stop":[ {"hooks":[]}]},\r\n "foreign":"한글 🧭"\r\n}\r\n'.encode())
        self.assertEqual((self.home / 'registration.json').read_bytes(),
            b'{"mcpServers": { "foreign":{"command":"invented-other"}}, "keep":1}\n')
        groups = json.loads((self.home / '.codex/hooks.json').read_bytes())['hooks']['Stop']
        self.assertEqual(groups[0], {'hooks': []})
        self.assertEqual(groups[1]['hooks'][0]['command'], 'invented-other')
        backup = list(self.home.glob('.activityprobe-cleanup-*'))
        self.assertEqual(len(backup), 1)
        self.assertEqual(stat.S_IMODE(backup[0].stat().st_mode), 0o700)
        manifest = json.loads((backup[0] / 'manifest.json').read_bytes())
        self.assertEqual(manifest[0]['role'], 'codex_config')
        for i, entry in enumerate(manifest):
            self.assertEqual((backup[0] / (str(i) + '.before')).read_bytes(), before[entry['path']])
            self.assertEqual(stat.S_IMODE((self.home / entry['path']).stat().st_mode), 0o640)
        self.assertTrue(all(stat.S_IMODE(p.stat().st_mode) == 0o600 for p in backup[0].iterdir()))
        after = self.tree()
        status, report = cleanup.execute(self.options(True))
        self.assertEqual(status, 0, report)
        self.assertEqual(report['counts']['files_changed'], 0)
        self.assertEqual(report['counts']['files_to_change'], 0)
        self.assertEqual(self.tree(), after)
        self.assertEqual(len(list(self.home.glob('.activityprobe-cleanup-*'))), 1)

    def test_mixed_group_blocks_all_files(self):
        # Ideal: no partial cleanup when a group also contains a foreign command.
        self.seed()
        mixed = group()
        mixed['hooks'].append({'type': 'command', 'command': 'invented-other', 'timeout': 15})
        self.write('.codex/hooks.json', json.dumps({'hooks': {'Stop': [mixed]}}))
        before = self.tree()
        status, report = cleanup.execute(self.options(True))
        self.assertEqual(status, 2)
        self.assertEqual(report['files']['codex_hooks'], 'mixed_hook_group')
        self.assertEqual(self.tree(), before)

    def test_modified_owned_group_and_shell_suffix_block(self):
        for change in ('matcher', 'timeout', 'suffix', 'provider', 'verb', 'event'):
            with self.subTest(change=change):
                owned = group()
                event = 'Stop'
                if change == 'matcher':
                    owned['matcher'] = '*'
                elif change == 'timeout':
                    owned['hooks'][0]['timeout'] = 16
                elif change == 'suffix':
                    owned['hooks'][0]['command'] += '; invented-other'
                elif change == 'provider':
                    owned['hooks'][0]['command'] = command('claude')
                elif change == 'verb':
                    owned['hooks'][0]['command'] = "'" + APP + "' mcp"
                else:
                    event = 'NotInstalledEvent'
                text = json.dumps({'hooks': {event: [owned]}})
                with self.assertRaises(cleanup.Refused):
                    cleanup.hook_plan(text, 'codex', self.own)

    def test_lookalike_foreign_binary_is_preserved(self):
        value = group()
        value['hooks'][0]['command'] = "'/another/ActivityProbeHook' codex"
        text = json.dumps({'hooks': {'Stop': [value]}})
        self.assertEqual(cleanup.hook_plan(text, 'codex', self.own), (text, 0, 0))

    def test_exact_fallback_and_legacy_commands(self):
        for command_text in ("'" + APP + "' hook claude", "'" + APP + "' hook-context"):
            value = group('claude')
            value['hooks'][0]['command'] = command_text
            text = json.dumps({'hooks': {'SessionStart': [value]}})
            after, count, _ = cleanup.hook_plan(text, 'claude', self.own)
            self.assertEqual(count, 1)
            self.assertEqual(json.loads(after), {'hooks': {'SessionStart': []}})
        self.assertFalse(self.own.command("'" + APP + "' hook-context", 'claude', 'Stop'))

    def test_empty_foreign_groups_never_removed_or_shifted(self):
        text = '{"hooks":{"Stop":[' + json.dumps(group()) + ', {"hooks":[]}]}}'
        after, count, placeholders = cleanup.hook_plan(text, 'codex', self.own)
        self.assertEqual(after, '{"hooks":{"Stop":[{"hooks": []}, {"hooks":[]}]}}')
        self.assertEqual((count, placeholders), (1, 1))
        self.assertEqual(cleanup.hook_plan(after, 'codex', self.own), (after, 0, 0))

    def test_hash_mismatch_and_foreign_mcp_are_preserved(self):
        config = '[hooks.state."' + KEY + '"]\ntrusted_hash="' + OTHER_HASH + '"\nenabled=false\n[mcp_servers.activityprobe]\ncommand="/foreign/ActivityProbe"\nargs=["mcp"]\n'
        self.assertEqual(cleanup.toml_plan(config, [(KEY, HASH)], self.own), (config, 0, 0, 1))
        store = '{"mcpServers":{"activityprobe":{"command":"/foreign/ActivityProbe","args":["mcp"]}}}'
        self.assertEqual(cleanup.mcp_json_plan(store, self.own), (store, 0))

    def test_foreign_http_registrations_remain_byte_identical(self):
        # Ideal: a URL transport cannot invoke our old executable and stays untouched.
        config = '[mcp_servers.activityprobe]\nurl="https://invented.invalid/mcp"\n'
        self.assertEqual(cleanup.toml_plan(config, [], self.own), (config, 0, 0, 0))
        store = '{"mcpServers":{"activityprobe":{"type":"http","url":"https://invented.invalid/mcp"}}}'
        self.assertEqual(cleanup.mcp_json_plan(store, self.own), (store, 0))

    def test_only_trusted_hash_is_removed_keeps_enabled_and_comments(self):
        config = '[hooks.state."' + KEY + '"] # header\n trusted_hash = "' + HASH + '" # note\n enabled=false\n'
        after, n, mcp, mismatch = cleanup.toml_plan(config, [(KEY, HASH)], self.own)
        self.assertEqual(after, '[hooks.state."' + KEY + '"] # header\n  # note\n enabled=false\n')
        self.assertEqual((n, mcp, mismatch), (1, 0, 0))

    def test_state_record_containing_only_our_hash_is_removed_without_empty_record(self):
        config = '# keep\n[hooks.state."' + KEY + '"] # keep header comment\ntrusted_hash="' + HASH + '" # keep field comment\n'
        after, n, _, _ = cleanup.toml_plan(config, [(KEY, HASH)], self.own)
        self.assertEqual(after, '# keep\n # keep header comment\n # keep field comment\n')
        self.assertEqual(n, 1)
        self.assertEqual(cleanup.toml_value(after), {})

    def test_dotted_trust_keys_and_crlf(self):
        config = 'hooks.state."' + KEY + '".trusted_hash="' + HASH + '"\r\nhooks.state."' + KEY + '".enabled=false\r\n'
        after, n, _, _ = cleanup.toml_plan(config, [(KEY, HASH)], self.own)
        self.assertEqual(after, '\r\nhooks.state."' + KEY + '".enabled=false\r\n')
        self.assertEqual(n, 1)

    def test_toml_fake_headers_inside_multiline_strings_are_untouched(self):
        config = "text = '''\n[mcp_servers.activityprobe]\ncommand = \"fake\"\n'''\n" + '[hooks.state."' + KEY + '"]\ntrusted_hash="' + HASH + '"\n'
        after, n, _, _ = cleanup.toml_plan(config, [(KEY, HASH)], self.own)
        expected = "text = '''\n[mcp_servers.activityprobe]\ncommand = \"fake\"\n'''\n\n\n"
        self.assertEqual(after, expected)
        self.assertEqual(n, 1)

    def test_unsupported_inline_toml_is_blocked_without_format_rewrite(self):
        config = 'hooks = { state = { "' + KEY + '" = {trusted_hash="' + HASH + '"} } }\n'
        with self.assertRaisesRegex(cleanup.Refused, 'unsupported_trust_layout'):
            cleanup.toml_plan(config, [(KEY, HASH)], self.own)

    def test_malformed_duplicate_missing_and_unreadable_are_untouched(self):
        for contents, reason in (('{', 'invalid_json'), ('{"hooks":{},"hooks":{}}', 'duplicate_json_key')):
            self.seed()
            self.write('.claude/settings.json', contents)
            before = self.tree()
            status, report = cleanup.execute(self.options(True))
            self.assertEqual(status, 2)
            self.assertEqual(report['files']['claude_hooks'], reason)
            self.assertEqual(self.tree(), before)
        self.write('.claude/settings.json', '{}').chmod(0)
        status, report = cleanup.execute(self.options(True))
        self.assertEqual(status, 2)
        self.assertEqual(report['files']['claude_hooks'], 'unreadable_file')
        (self.home / '.claude/settings.json').unlink()
        status, report = cleanup.execute(self.options(True))
        self.assertEqual(status, 2)
        self.assertEqual(report['files']['claude_hooks'], 'missing')
        self.assertFalse((self.home / '.claude/settings.json').exists())

    def test_invalid_toml_and_untrusted_ledger(self):
        self.seed()
        self.write('.codex/config.toml', '[broken\n')
        before = self.tree()
        status, report = cleanup.execute(self.options(True))
        self.assertEqual(status, 2)
        self.assertEqual(report['files']['codex_config'], 'invalid_toml')
        self.assertEqual(self.tree(), before)
        self.write('.codex/config.toml', '')
        self.write('ledger.json', '{"codex-approved":[["key","invalid"]]}')
        status, report = cleanup.execute(self.options(True))
        self.assertEqual(status, 2)
        self.assertEqual(report['files']['ledger'], 'invalid_approval_ledger')

    def test_apply_without_live_switch_refuses_before_any_file_read(self):
        options = self.options(True)
        options.live_switch = False
        with patch.object(cleanup, 'Home', side_effect=AssertionError('must not read')):
            status, report = cleanup.execute(options)
        self.assertEqual(status, 2)
        self.assertEqual(report['reason'], 'live_switch_required')

    def test_file_and_parent_symlinks_never_followed(self):
        # Outside is another invented fixture, never a real user path.
        with tempfile.TemporaryDirectory(dir=self.home.parent) as folder:
            outside = Path(folder)
            target = outside / 'settings.json'
            target.write_text('outside-sentinel')
            own = self.home / '.claude/settings.json'
            own.unlink()
            own.symlink_to(target)
            status, report = cleanup.execute(self.options(True))
            self.assertEqual(status, 2)
            self.assertEqual(report['files']['claude_hooks'], 'unreadable_or_unsafe')
            self.assertEqual(target.read_text(), 'outside-sentinel')
            own.unlink()
            own.parent.rmdir()
            own.parent.symlink_to(outside, target_is_directory=True)
            status, report = cleanup.execute(self.options(True))
            self.assertEqual(status, 2)
            self.assertEqual(target.read_text(), 'outside-sentinel')

    def test_parent_traversal_and_hardlink_refuse(self):
        options = self.options(True)
        options.claude_mcp_file = '../outside.json'
        status, report = cleanup.execute(options)
        self.assertEqual(status, 2)
        self.assertEqual(report['reason'], 'relative_path_required')
        target = self.home / '.claude/settings.json'
        os.link(target, self.home / 'hardlink')
        status, report = cleanup.execute(self.options(True))
        self.assertEqual(status, 2)
        self.assertEqual(report['files']['claude_hooks'], 'unsafe_file')

    def test_concurrent_change_prevents_replace_and_does_not_rollback_newer_content(self):
        self.seed()
        before_hooks = (self.home / '.codex/hooks.json').read_bytes()
        def concurrent(role):
            self.assertEqual(role, 'codex_config')
            self.write('.codex/config.toml', '# newer invented save\n')
        status, report = cleanup.execute(self.options(True), before_replace=concurrent)
        self.assertEqual(status, 2)
        self.assertEqual(report['reason'], 'concurrent_change')
        self.assertEqual(report['counts']['files_changed'], 0)
        self.assertEqual((self.home / '.codex/config.toml').read_text(), '# newer invented save\n')
        self.assertEqual((self.home / '.codex/hooks.json').read_bytes(), before_hooks)
        self.assertEqual(len(list(self.home.glob('.activityprobe-cleanup-*'))), 1)

    def test_partial_io_failure_reports_earlier_commit_and_backups(self):
        self.seed()
        def concurrent(role):
            if role == 'codex_hooks':
                self.write('.codex/hooks.json', '{"newer":true}\n')
        status, report = cleanup.execute(self.options(True), before_replace=concurrent)
        self.assertEqual(status, 2)
        self.assertEqual(report['reason'], 'concurrent_change')
        self.assertEqual(report['counts']['files_changed'], 1)
        self.assertEqual(report['files']['codex_config'], 'verified_before_failure')
        self.assertEqual((self.home / '.codex/hooks.json').read_text(), '{"newer":true}\n')
        self.assertEqual((self.home / '.claude/settings.json').read_bytes().count(b'ActivityProbeHook'), 1)

    def test_save_after_rename_reports_the_committed_write_even_when_verification_fails(self):
        self.seed()
        replace = os.replace
        def competing_save(*args, **kwargs):
            replace(*args, **kwargs)
            self.write('.codex/config.toml', '# newer save after rename\n')
        with patch.object(cleanup.os, 'replace', side_effect=competing_save):
            status, report = cleanup.execute(self.options(True))
        self.assertEqual(status, 2)
        self.assertEqual(report['reason'], 'post_write_verification_failed')
        self.assertEqual(report['counts']['files_changed'], 1)
        self.assertEqual(report['files']['codex_config'], 'verification_failed_after_commit')
        self.assertEqual((self.home / '.codex/config.toml').read_text(), '# newer save after rename\n')

    def test_cli_output_never_contains_contents_and_never_invokes_an_agent(self):
        self.seed()
        self.write('.claude/settings.json', 'invented-sensitive-sentinel {')
        args = ['--dry-run', '--home', str(self.home), '--old-app', APP,
                '--claude-mcp-file', 'registration.json', '--metadata-file', 'ledger.json']
        result = subprocess.run([sys.executable, '-I', str(SCRIPT)] + args, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(b'invented-sensitive-sentinel', result.stdout + result.stderr)
        self.assertEqual(result.stderr, b'')
        self.assertEqual(json.loads(result.stdout)['files']['claude_hooks'], 'invalid_json')

    def test_registration_wrong_argument_and_malformed_command_block(self):
        # Ideal: a same executable with another verb is ambiguous; malformed stores never crash.
        for value, reason in (({'command': APP, 'args': ['different']}, 'ambiguous_registration'),
                              ({'command': [APP], 'args': ['mcp']}, 'invalid_registration')):
            with self.subTest(reason=reason):
                self.write('registration.json', json.dumps({'mcpServers': {'activityprobe': value}}))
                before = self.tree()
                status, report = cleanup.execute(self.options(True))
                self.assertEqual(status, 2)
                self.assertEqual(report['files']['claude_mcp'], reason)
                self.assertEqual(self.tree(), before)

    def test_modified_registration_blocks_entire_preflight_without_writes(self):
        # Ideal: either store's modified registration blocks even otherwise removable files.
        changes = ({'url': 'https://invented.invalid/mcp'}, {'url': ''}, {'url': None},
                   {'type': 'http'}, {'type': 'command'}, {'type': None},
                   {'transport': 'http'}, {'transport': 'stdio'}, {'transport': None},
                   {'env': {}}, {'enabled': True}, {'invented_extra': 'keep'})
        for provider in ('claude', 'codex'):
            variants = list(changes)
            # Even plausible plain-command metadata must match what this installer wrote.
            variants.append({'type': 'stdio'} if provider == 'codex' else {'type': 'missing'})
            for change in variants:
                for apply in (False, True):
                    with self.subTest(provider=provider, change=change, apply=apply):
                        self.seed()
                        if provider == 'claude':
                            value = {'command': APP, 'args': ['mcp'], 'type': 'stdio'}
                            value.update(change)
                            if change == {'type': 'missing'}:
                                del value['type']
                            self.write('registration.json', json.dumps({'mcpServers': {'activityprobe': value}}))
                        else:
                            extra = ''.join(key + ' = ' + json.dumps(value) + '\n'
                                            for key, value in change.items() if value is not None)
                            # TOML has no null. An empty inline table still denotes an extra identity field.
                            extra += ''.join(key + ' = {}\n' for key, value in change.items() if value is None)
                            self.write('.codex/config.toml', self.config_before.replace(
                                '[mcp_servers.foreign]', extra + '[mcp_servers.foreign]'))
                        before = self.tree()
                        with patch.object(cleanup, 'backup_folder') as backup, \
                             patch.object(cleanup.os, 'replace') as replace, \
                             patch.object(cleanup, 'write_new') as write:
                            status, report = cleanup.execute(self.options(apply))
                        self.assertEqual(status, 2, report)
                        role = 'claude_mcp' if provider == 'claude' else 'codex_config'
                        self.assertEqual(report['files'][role], 'ambiguous_registration')
                        self.assertEqual(report['status'], 'blocked')
                        self.assertEqual(report['counts']['files_changed'], 0)
                        self.assertGreater(report['counts']['files_to_change'], 0)
                        backup.assert_not_called()
                        replace.assert_not_called()
                        write.assert_not_called()
                        self.assertEqual(self.tree(), before)
                        self.assertFalse(list(self.home.glob('.activityprobe-cleanup-*')))

    def test_explicit_codex_user_store_never_touches_the_default_store(self):
        self.seed()
        selected = self.write('invented-codex/config.toml', self.config_before)
        default = self.write('.codex/config.toml', '# unrelated default store\n')
        options = self.options(True)
        options.codex_config_file = 'invented-codex/config.toml'
        status, report = cleanup.execute(options)
        self.assertEqual(status, 0, report)
        self.assertEqual(selected.read_text(), self.config_expected)
        self.assertEqual(default.read_text(), '# unrelated default store\n')

    def test_old_history_backup_and_ledger_remain_untouched(self):
        self.seed()
        previous = self.write('.claude/settings.json.before-activityprobe', 'invented historical original')
        ledger = (self.home / 'ledger.json').read_bytes()
        status, report = cleanup.execute(self.options(True))
        self.assertEqual(status, 0, report)
        self.assertEqual(previous.read_text(), 'invented historical original')
        self.assertEqual((self.home / 'ledger.json').read_bytes(), ledger)

    def test_parent_replacement_is_detected_before_any_rename(self):
        self.seed()
        moved = self.home / 'detached'
        def concurrent(role):
            (self.home / '.codex').rename(moved)
            (self.home / '.codex').mkdir()
            self.write('.codex/config.toml', '# newer directory sentinel\n')
            self.write('.codex/hooks.json', '{}')
        status, report = cleanup.execute(self.options(True), before_replace=concurrent)
        self.assertEqual(status, 2)
        self.assertEqual(report['reason'], 'concurrent_change')
        self.assertEqual((self.home / '.codex/config.toml').read_text(), '# newer directory sentinel\n')
        self.assertEqual((moved / 'config.toml').read_text(), self.config_before)

    def test_python_without_tomllib_refuses_before_reading(self):
        with patch.object(cleanup, 'tomllib', None), patch.object(cleanup, 'Home', side_effect=AssertionError('must not read')):
            status, report = cleanup.execute(self.options(True))
        self.assertEqual(status, 2)
        self.assertEqual(report['reason'], 'python_3_11_required')

    def test_json_removal_first_middle_last_and_multiple_runs(self):
        # Ideal retained tokens and all whitespace outside removed spans remain verbatim.
        for indices, expected in [([0], '[  1 , 2 , 3 ]'), ([1], '[ 0 ,  2 , 3 ]'),
                                  ([3], '[ 0 , 1 , 2  ]'), ([0, 2], '[  1 ,  3 ]'),
                                  ([0, 1, 2, 3], '[  ]')]:
            text = '{"x":[ 0 , 1 , 2 , 3 ]}'
            node = cleanup.member(cleanup.json_tree(text), 'x')
            after = cleanup.patched(text, cleanup.remove_items(text, node, indices))
            self.assertEqual(after, '{"x":' + expected + '}')


if __name__ == '__main__':
    unittest.main()
