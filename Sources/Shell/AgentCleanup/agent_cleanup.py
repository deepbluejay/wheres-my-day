#!/usr/bin/env python3
"""One-shot operator tool. Never imported or invoked by normal connection behavior."""
import argparse
import copy
import errno
import fcntl
import json
import os
import re
import shlex
import stat
import sys
import uuid
from dataclasses import dataclass

try:
    import tomllib
except ImportError:
    tomllib = None

MAX_FILE = 16 * 1024 * 1024
EVENTS = {'SessionStart', 'UserPromptSubmit', 'Stop', 'SubagentStart', 'SubagentStop', 'SessionEnd'}


class Refused(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise Refused(reason)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate_json_key')
        result[key] = value
    return result


def json_value(text):
    try:
        return json.loads(text, object_pairs_hook=unique,
                          parse_constant=lambda _: (_ for _ in ()).throw(Refused('invalid_json')))
    except (ValueError, UnicodeError, RecursionError):
        raise Refused('invalid_json') from None


@dataclass
class Node:
    start: int
    end: int
    value: object
    children: list
    key: object = None
    member_start: int = 0


def json_tree(text):
    value = json_value(text)
    decoder = json.JSONDecoder()

    def whitespace(i):
        while i < len(text) and text[i] in ' \t\r\n':
            i += 1
        return i

    def read(i):
        start = i
        children = []
        if text[i] in '{[':
            is_object = text[i] == '{'
            i = whitespace(i + 1)
            while text[i] != ('}' if is_object else ']'):
                member_start, key = i, None
                if is_object:
                    key, i = decoder.raw_decode(text, i)
                    i = whitespace(whitespace(i) + 1)
                child = read(i)
                child.key, child.member_start = key, member_start
                children.append(child)
                i = whitespace(child.end)
                if text[i] == ',':
                    i = whitespace(i + 1)
                else:
                    break
            end = i + 1
        else:
            _, end = decoder.raw_decode(text, i)
        return Node(start, end, json_value(text[start:end]), children)

    try:
        root = read(whitespace(0))
    except (IndexError, ValueError, RecursionError):
        raise Refused('invalid_json') from None
    require(isinstance(value, dict), 'json_object_required')
    return root


def member(node, key):
    return next((c for c in node.children if c.key == key), None)


def remove_items(text, node, indices):
    """Delete only owned tokens and the comma needed to keep their container valid."""
    indices = sorted(indices)
    runs = []
    for index in indices:
        if runs and index == runs[-1][-1] + 1:
            runs[-1].append(index)
        else:
            runs.append([index])
    edits = []
    for run in runs:
        first, last = run[0], run[-1]
        start, end = node.children[first].member_start, node.children[last].end
        if last < len(node.children) - 1:
            comma = text.index(',', end, node.children[last + 1].member_start)
            end = comma + 1
        elif first > 0:
            start = text.index(',', node.children[first - 1].end, start)
        edits.append((start, end, ''))
    return edits


def patched(text, edits):
    limit = len(text)
    for start, end, replacement in sorted(edits, reverse=True):
        require(0 <= start <= end <= limit, 'overlapping_edits')
        text = text[:start] + replacement + text[end:]
        limit = start
    return text


class Ownership:
    def __init__(self, apps, hooks):
        self.apps = set(apps)
        self.hooks = set(hooks)
        for path in self.apps | self.hooks:
            require(os.path.isabs(path) and os.path.normpath(path) == path
                    and not any(ord(c) < 32 or ord(c) == 127 for c in path), 'absolute_identity_required')
        require(all(os.path.basename(p) == 'ActivityProbe' for p in self.apps), 'old_app_identity_required')
        require(all(os.path.basename(p) == 'ActivityProbeHook' for p in self.hooks), 'old_hook_identity_required')

    def command(self, command, provider, event):
        if not isinstance(command, str):
            return False
        # A shell wrapper, redirection, substitution, or suffix is never an executable identity.
        forms = []
        for path in self.hooks:
            forms += [(path, [provider])]
        for path in self.apps:
            forms += [(path, ['hook', provider])]
            if event == 'SessionStart':
                forms += [(path, ['hook-context'])]
        for path, args in forms:
            accepted = [shlex.quote(path), "'" + path + "'", json.dumps(path, ensure_ascii=False)]
            # Double quoting expands these characters in a shell, so is not a literal identity.
            if any(c in path for c in '$`\\'):
                accepted = [shlex.quote(path), "'" + path + "'"]
            if "'" in path:
                accepted = [shlex.quote(path)]
            if command in {exe + ' ' + ' '.join(args) for exe in accepted}:
                return True
        return False

    def suspected(self, command):
        return isinstance(command, str) and any(p in command for p in self.apps | self.hooks)

    def registration(self, value, provider):
        require(isinstance(value, dict), 'invalid_registration')
        command = value.get('command')
        if command is None and isinstance(value.get('url'), str):
            return False
        require(isinstance(command, str), 'invalid_registration')
        if command not in self.apps:
            return False
        expected = {'command': command, 'args': ['mcp']}
        if provider == 'claude':
            expected['type'] = 'stdio'
        # A matching executable alone cannot claim a modified or additional destination.
        require(value == expected, 'ambiguous_registration')
        return True


def hook_plan(text, provider, ownership):
    root = json_tree(text)
    expected = copy.deepcopy(root.value)
    hooks = member(root, 'hooks')
    if hooks is None:
        return text, 0, 0
    require(isinstance(hooks.value, dict), 'invalid_hooks')
    edits, count, placeholders = [], 0, 0
    for event in hooks.children:
        require(isinstance(event.value, list), 'invalid_hook_groups')
        owned = []
        for index, group in enumerate(event.children):
            require(isinstance(group.value, dict) and isinstance(group.value.get('hooks'), list), 'invalid_hook_group')
            commands = group.value['hooks']
            require(all(isinstance(c, dict) for c in commands), 'invalid_hook_command')
            flags = [ownership.command(c.get('command'), provider, event.key) for c in commands]
            suspicious = any(ownership.suspected(c.get('command')) and not flag for c, flag in zip(commands, flags))
            require(not suspicious, 'ambiguous_hook_command')
            if not any(flags):
                continue
            require(all(flags), 'mixed_hook_group')
            require(event.key in EVENTS and (provider != 'codex' or event.key != 'SessionEnd'), 'ambiguous_hook_event')
            require(set(group.value) == {'hooks'} and all(set(c) == {'type', 'command', 'timeout'}
                    and c['type'] == 'command' and type(c['timeout']) is int and c['timeout'] == 15
                    for c in commands), 'ambiguous_hook_group')
            owned.append(index)
            count += len(commands)
        # Even an existing empty group may have positional state. Never move a foreign group.
        last_foreign = max((i for i in range(len(event.children)) if i not in owned), default=-1)
        delete = []
        for index in owned:
            if provider == 'codex' and index < last_foreign:
                inner = member(event.children[index], 'hooks')
                edits += remove_items(text, inner, range(len(inner.children)))
                expected['hooks'][event.key][index]['hooks'] = []
                placeholders += 1
            else:
                delete.append(index)
        edits += remove_items(text, event, delete)
        for index in reversed(delete):
            del expected['hooks'][event.key][index]
    result = patched(text, edits)
    require(json_value(result) == expected, 'hook_verification_failed')
    return result, count, placeholders


def mcp_json_plan(text, ownership):
    root = json_tree(text)
    servers = member(root, 'mcpServers')
    if servers is None:
        return text, 0
    require(isinstance(servers.value, dict), 'invalid_registration_store')
    server = member(servers, 'activityprobe')
    if server is None or not ownership.registration(server.value, 'claude'):
        return text, 0
    expected = copy.deepcopy(root.value)
    del expected['mcpServers']['activityprobe']
    result = patched(text, remove_items(text, servers, [servers.children.index(server)]))
    require(json_value(result) == expected, 'registration_verification_failed')
    return result, 1


def toml_value(text):
    require(tomllib is not None, 'python_3_11_required')
    try:
        return tomllib.loads(text)
    except (ValueError, RecursionError):
        raise Refused('invalid_toml') from None


def key_path(source):
    """Decode a TOML dotted key without mistaking dots inside a quoted key for separators."""
    parts, i = [], 0
    token = re.compile(r'''\s*(?:([A-Za-z0-9_-]+)|("(?:[^"\\\r\n]|\\.)*")|('[^'\r\n]*'))\s*''')
    while i < len(source):
        match = token.match(source, i)
        require(match is not None, 'unsupported_toml_layout')
        raw = match.group(2) or match.group(3)
        parts.append(match.group(1) if raw is None else toml_value('v=' + raw)['v'])
        i = match.end()
        if i < len(source):
            require(source[i] == '.', 'unsupported_toml_layout')
            i += 1
            require(i < len(source), 'unsupported_toml_layout')
    require(bool(parts), 'unsupported_toml_layout')
    return tuple(parts)


def statements(text):
    """Find logical statements, ignoring header-like text in comments and multiline strings."""
    start, i, quote, depth = 0, 0, None, 0
    while i < len(text):
        if quote:
            if text.startswith(quote, i):
                i += len(quote)
                quote = None
            elif quote[0] == '"' and text[i] == '\\':
                i += 2
            else:
                i += 1
        elif text[i] in "\"'":
            quote = text[i] * (3 if text.startswith(text[i] * 3, i) else 1)
            i += len(quote)
        elif text[i] == '#':
            end = text.find('\n', i)
            i = len(text) if end < 0 else end
        elif text[i] in '[{':
            depth += 1
            i += 1
        elif text[i] in ']}':
            depth -= 1
            i += 1
        elif text[i] == '\n' and depth == 0:
            yield start, i, text[start:i]
            i += 1
            start = i
        else:
            i += 1
    if start < len(text):
        yield start, len(text), text[start:]


def code_end(source):
    quote, i = None, 0
    while i < len(source):
        if quote:
            if source.startswith(quote, i):
                i += len(quote)
                quote = None
            elif quote[0] == '"' and source[i] == '\\':
                i += 2
            else:
                i += 1
        elif source[i] in "\"'":
            quote = source[i] * (3 if source.startswith(source[i] * 3, i) else 1)
            i += len(quote)
        elif source[i] == '#':
            return i
        else:
            i += 1
    return len(source)


def normalized(value):
    if isinstance(value, dict):
        return {k: normalized(v) for k, v in value.items() if not isinstance(v, dict) or normalized(v)}
    if isinstance(value, list):
        return [normalized(v) for v in value]
    return value


def toml_plan(text, approvals, ownership):
    before = toml_value(text)
    expected = copy.deepcopy(before)
    hooks = before.get('hooks', {})
    require(isinstance(hooks, dict) and isinstance(hooks.get('state', {}), dict), 'invalid_trust_state')
    states = hooks.get('state', {})
    clear, mismatched = set(), 0
    for key, digest in approvals:
        state = states.get(key, {})
        require(isinstance(state, dict), 'invalid_trust_state')
        current = state.get('trusted_hash')
        if current == digest:
            clear.add(('hooks', 'state', key, 'trusted_hash'))
            del expected['hooks']['state'][key]['trusted_hash']
        elif current is not None:
            mismatched += 1
    servers = before.get('mcp_servers', {})
    require(isinstance(servers, dict), 'invalid_registration_store')
    remove_mcp = 'activityprobe' in servers and ownership.registration(servers['activityprobe'], 'codex')
    mcp_path = ('mcp_servers', 'activityprobe')
    if remove_mcp:
        del expected['mcp_servers']['activityprobe']
    edits, found = [], set()
    table = ()
    for start, end, source in statements(text):
        code = source[:code_end(source)].strip()
        if not code:
            continue
        left = len(source) - len(source.lstrip())
        right = code_end(source)
        right -= len(source[:right]) - len(source[:right].rstrip())
        if code.startswith('['):
            array = code.startswith('[[')
            table = key_path(code[2:-2] if array else code[1:-1])
            if remove_mcp and table[:2] == mcp_path:
                require(not array, 'unsupported_toml_layout')
                edits.append((start + left, start + right, ''))
            elif (len(table) == 3 and table[:2] == ('hooks', 'state')
                  and table + ('trusted_hash',) in clear and set(states[table[2]]) == {'trusted_hash'}):
                # The whole record is ours only when no user choice or other field remains.
                edits.append((start + left, start + right, ''))
            continue
        # Only the key is scanned: '=' inside values is irrelevant.
        key_end = re.match(r'''(?:[^="']|"(?:[^"\\]|\\.)*"|'[^']*')*''', code).end()
        require(key_end < len(code) and code[key_end] == '=', 'unsupported_toml_layout')
        path = table + key_path(code[:key_end].strip())
        if path in clear:
            require('\n' not in code, 'unsupported_toml_layout')
            found.add(path)
            edits.append((start + left, start + right, ''))
        elif remove_mcp and path[:2] == mcp_path:
            # Multiline registration values can contain comments; preserve them by refusing.
            require('\n' not in code, 'unsupported_toml_layout')
            edits.append((start + left, start + right, ''))
    require(found == clear, 'unsupported_trust_layout')
    result = patched(text, edits)
    require(normalized(toml_value(result)) == normalized(expected), 'toml_verification_failed')
    return result, len(clear), int(remove_mcp), mismatched


class Home:
    """All IO is relative to pinned directory descriptors; no symlink is followed."""
    def __init__(self, path):
        require(os.path.isabs(path) and os.path.normpath(path) == path, 'absolute_home_required')
        fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in path.split('/')[1:]:
                if not part:
                    continue
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = child
            require(os.fstat(fd).st_uid == os.getuid(), 'foreign_home_owner')
            self.fd = fd
        except BaseException:
            os.close(fd)
            raise

    @staticmethod
    def parts(path):
        parts = path.split('/')
        require(path and all(p not in ('', '.', '..') for p in parts) and not os.path.isabs(path), 'relative_path_required')
        return parts

    def parent(self, path):
        parts = self.parts(path)
        fd = os.dup(self.fd)
        try:
            for part in parts[:-1]:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                require(os.fstat(child).st_uid == os.getuid(), 'foreign_directory_owner')
                os.close(fd)
                fd = child
            return fd, parts[-1]
        except BaseException:
            os.close(fd)
            raise

    def close(self):
        os.close(self.fd)


class Snapshot:
    def __init__(self, home, path):
        self.home, self.path = home, path
        self.parent, self.name = home.parent(path)
        self.fd = -1
        try:
            self.fd = os.open(self.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.parent)
            info = os.fstat(self.fd)
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1,
                    'unsafe_file')
            require(info.st_mode & 0o444 != 0, 'unreadable_file')
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.info = info
            self.data = self.read()
            self.verify()
        except BaseException:
            self.close()
            raise

    def read(self):
        os.lseek(self.fd, 0, os.SEEK_SET)
        data = bytearray()
        while True:
            chunk = os.read(self.fd, min(65536, MAX_FILE + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
            require(len(data) <= MAX_FILE, 'file_too_large')
        return bytes(data)

    @staticmethod
    def stamp(info):
        return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
                info.st_mode, info.st_uid, info.st_gid, info.st_nlink)

    def verify(self):
        parent, name = self.home.parent(self.path)
        try:
            require((os.fstat(parent).st_dev, os.fstat(parent).st_ino) ==
                    (os.fstat(self.parent).st_dev, os.fstat(self.parent).st_ino), 'concurrent_change')
            require(self.stamp(os.stat(name, dir_fd=parent, follow_symlinks=False)) == self.stamp(self.info)
                    and self.stamp(os.fstat(self.fd)) == self.stamp(self.info)
                    and self.read() == self.data, 'concurrent_change')
        finally:
            os.close(parent)

    def close(self):
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1
        os.close(self.parent)


def write_new(parent, name, data, mode):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
    try:
        os.fchmod(fd, mode)
        view = memoryview(data)
        while view:
            n = os.write(fd, view)
            require(n > 0, 'write_failed')
            view = view[n:]
        os.fsync(fd)
    finally:
        os.close(fd)


def backup_folder(home):
    name = '.activityprobe-cleanup-' + uuid.uuid4().hex
    os.mkdir(name, 0o700, dir_fd=home.fd)
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=home.fd)
    os.fchmod(fd, 0o700)
    return name, fd


def apply_plans(home, plans, snapshots, before_replace=None, progress=None):
    """Quiescent sessions are required: advisory locks cannot stop noncooperating writers."""
    for snapshot in snapshots:
        snapshot.verify()
    backup_name, backup_fd = backup_folder(home)
    changed = 0
    try:
        manifest = []
        for index, (role, snapshot, data) in enumerate(plans):
            write_new(backup_fd, str(index) + '.before', snapshot.data, 0o600)
            manifest.append({'role': role, 'path': snapshot.path, 'mode': stat.S_IMODE(snapshot.info.st_mode),
                             'uid': snapshot.info.st_uid, 'gid': snapshot.info.st_gid})
        write_new(backup_fd, 'manifest.json', json.dumps(manifest, sort_keys=True).encode(), 0o600)
        os.fsync(backup_fd)
        for role, snapshot, data in plans:
            temporary = '.activityprobe-cleanup-' + uuid.uuid4().hex
            try:
                write_new(snapshot.parent, temporary, data, 0o600)
                fd = os.open(temporary, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=snapshot.parent)
                try:
                    os.fchown(fd, snapshot.info.st_uid, snapshot.info.st_gid)
                    os.fchmod(fd, stat.S_IMODE(snapshot.info.st_mode))
                    os.fsync(fd)
                finally:
                    os.close(fd)
                if before_replace:
                    before_replace(role)
                # Recheck every not-yet-written input, including the app-owned trust ledger.
                for pending in snapshots:
                    pending.verify()
                os.replace(temporary, snapshot.name, src_dir_fd=snapshot.parent, dst_dir_fd=snapshot.parent)
                changed += 1
                if progress:
                    progress(role, False)
                os.fsync(snapshot.parent)
                after = Snapshot(home, snapshot.path)
                try:
                    require(after.data == data and stat.S_IMODE(after.info.st_mode) == stat.S_IMODE(snapshot.info.st_mode)
                            and after.info.st_uid == snapshot.info.st_uid and after.info.st_gid == snapshot.info.st_gid,
                            'post_write_verification_failed')
                finally:
                    after.close()
                if progress:
                    progress(role, True)
            finally:
                try:
                    os.unlink(temporary, dir_fd=snapshot.parent)
                except FileNotFoundError:
                    pass
            snapshots.remove(snapshot)
        return changed, backup_name
    finally:
        os.close(backup_fd)


def approvals_from(text):
    value = json_tree(text).value.get('codex-approved', [])
    require(isinstance(value, list), 'invalid_approval_ledger')
    result = []
    for pair in value:
        require(isinstance(pair, list) and len(pair) == 2 and all(isinstance(s, str) and s for s in pair)
                and re.fullmatch(r'sha256:[0-9a-fA-F]{64}', pair[1]), 'invalid_approval_ledger')
        require(pair[0] not in {key for key, _ in result}, 'ambiguous_approval_ledger')
        result.append(tuple(pair))
    return result


def execute(options, before_replace=None):
    report = {'mode': 'apply' if options.apply else 'dry_run', 'files': {},
              'counts': {'hooks': 0, 'placeholders': 0, 'trust': 0, 'mcp': 0,
                         'preserved_trust_mismatches': 0, 'files_to_change': 0, 'files_changed': 0}}
    home, snapshots, plans = None, [], []
    try:
        require(tomllib is not None, 'python_3_11_required')
        require(not options.apply or options.live_switch, 'live_switch_required')
        require(not options.live_switch or options.apply, 'apply_required')
        ownership = Ownership(options.old_app, options.old_hook)
        paths = {'ledger': options.metadata_file, 'codex_config': options.codex_config_file,
                 'codex_hooks': '.codex/hooks.json', 'claude_hooks': '.claude/settings.json',
                 'claude_mcp': options.claude_mcp_file}
        for path in paths.values():
            Home.parts(path)
        require(len(set(paths.values())) == len(paths), 'overlapping_input_files')
        home = Home(options.home)
        inputs, blocked = {}, False
        for role, path in paths.items():
            try:
                snapshot = Snapshot(home, path)
                snapshots.append(snapshot)
                inputs[role] = snapshot
                report['files'][role] = 'checked'
            except FileNotFoundError:
                report['files'][role] = 'missing'
                blocked = True
            except (OSError, Refused) as error:
                report['files'][role] = error.args[0] if isinstance(error, Refused) else ('unreadable_file' if error.errno == errno.EACCES else 'unreadable_or_unsafe')
                blocked = True
        approvals = None
        if 'ledger' in inputs:
            try:
                approvals = approvals_from(inputs['ledger'].data.decode('utf-8'))
            except (Refused, UnicodeError) as error:
                report['files']['ledger'] = error.args[0] if isinstance(error, Refused) else 'invalid_utf8'
                blocked = True
        for role in ('codex_config', 'codex_hooks', 'claude_hooks', 'claude_mcp'):
            if role not in inputs:
                continue
            snapshot = inputs[role]
            try:
                text = snapshot.data.decode('utf-8')
                if role == 'codex_config':
                    require(approvals is not None, 'approval_ledger_required')
                    result, trust, mcp, mismatch = toml_plan(text, approvals, ownership)
                    report['counts']['trust'] += trust
                    report['counts']['mcp'] += mcp
                    report['counts']['preserved_trust_mismatches'] += mismatch
                    verify = lambda value: toml_plan(value, approvals, ownership)[1:3] == (0, 0)
                elif role == 'claude_mcp':
                    result, mcp = mcp_json_plan(text, ownership)
                    report['counts']['mcp'] += mcp
                    verify = lambda value: mcp_json_plan(value, ownership)[1] == 0
                else:
                    provider = 'codex' if role == 'codex_hooks' else 'claude'
                    result, hooks, placeholders = hook_plan(text, provider, ownership)
                    report['counts']['hooks'] += hooks
                    report['counts']['placeholders'] += placeholders
                    verify = lambda value: hook_plan(value, provider, ownership)[1] == 0
                require(verify(result), 'owned_entries_remain')
                if result != text:
                    plans.append((role, snapshot, result.encode('utf-8')))
                    report['files'][role] = 'would_change'
                else:
                    report['files'][role] = 'unchanged'
            except (Refused, UnicodeError, RecursionError) as error:
                report['files'][role] = error.args[0] if isinstance(error, Refused) else 'invalid_encoding_or_depth'
                blocked = True
        report['counts']['files_to_change'] = len(plans)
        if blocked:
            report['status'] = 'blocked'
            return 2, report
        for snapshot in snapshots:
            snapshot.verify()
        if options.apply and plans:
            def progress(role, verified):
                if not verified:
                    report['counts']['files_changed'] += 1
                report['files'][role] = 'verified' if verified else 'committed'
            changed, _ = apply_plans(home, plans, list(snapshots), before_replace, progress)
            require(changed == report['counts']['files_changed'], 'commit_count_verification_failed')
            for role, _, _ in plans:
                report['files'][role] = 'verified'
        report['status'] = 'verified' if options.apply else 'dry_run'
        return 0, report
    except (OSError, Refused, UnicodeError, RecursionError):
        # Never expose exception text from parsers, OS errors, paths or file contents.
        error = sys.exc_info()[1]
        report['status'] = 'blocked'
        report['reason'] = error.args[0] if isinstance(error, Refused) else 'io_or_validation_failed'
        # Count renames when they happen, even if another writer wins before verification.
        for role, state in list(report['files'].items()):
            if state == 'verified':
                report['files'][role] = 'verified_before_failure'
            elif state == 'committed':
                report['files'][role] = 'verification_failed_after_commit'
        return 2, report
    finally:
        for snapshot in snapshots:
            snapshot.close()
        if home:
            home.close()


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Refused('invalid_arguments')


def arguments(argv):
    parser = Parser(description='One-time exact-byte agent cleanup; requires Python 3.11+. Quiesce old recorder and agent sessions first.')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--dry-run', action='store_true')
    mode.add_argument('--apply', action='store_true')
    parser.add_argument('--live-switch', action='store_true')
    parser.add_argument('--home', required=True, help='Explicit absolute home; no defaults or discovery')
    parser.add_argument('--old-app', action='append', required=True, help='Exact old ActivityProbe executable identity; repeat for known installs')
    parser.add_argument('--old-hook', action='append', default=[], help='Exact old ActivityProbeHook identity; repeat for known installs')
    parser.add_argument('--claude-mcp-file', required=True, help='Home-relative JSON store containing only the user-scope mcpServers map at its root; operator must establish the scope')
    parser.add_argument('--codex-config-file', default='.codex/config.toml',
                        help='Home-relative operator-established Codex user config store')
    parser.add_argument('--metadata-file', default='Library/Application Support/ActivityProbe/agent-hooks.json')
    return parser.parse_args(argv)


def main(argv=None):
    try:
        status, report = execute(arguments(sys.argv[1:] if argv is None else argv))
    except Refused:
        status, report = 2, {'status': 'blocked', 'reason': 'invalid_arguments'}
    print(json.dumps(report, sort_keys=True))
    return status


if __name__ == '__main__':
    sys.exit(main())
