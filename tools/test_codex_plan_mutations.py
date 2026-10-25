#!/usr/bin/env python3
"""Mutation checks for the ChatGPT conversation, on an expendable /tmp copy without .git."""
import pathlib
import subprocess
import sys

LAUNCH = 'AdapterTests/testEveryCodexChildUsesPlanTokenAndEphemeralCredentialStore'
ERRORS = 'AdapterTests/testPlanFailuresUpdateTheTokenPortWithoutReplayingTools|AdapterTests/testPlanTokenRefresh|AdapterTests/testNativePlanFailures|CodexPlanFailureTests'
SCOPED = 'ChatGPTSignInTests/testSummaryRefusalDoesNotBlockADifferentConversationShape'
PROCESS = 'Sources/Outbound/CodexPlanProcess.swift'
AGENT = 'Sources/Outbound/CodexConversationAgent.swift'
MUTATIONS = [
    ('token', PROCESS, 'values[Self.tokenVariable] = token.value',
     'values[Self.tokenVariable] = "invented-wrong"', LAUNCH),
    ('codex-home', PROCESS, 'values["CODEX_HOME"] = home.path',
     'values["CODEX_HOME"] = configuration.codexHome.path', LAUNCH),
    ('shell-home', PROCESS, 'for key in ["HOME", "CFFIXED_USER_HOME", "ZDOTDIR"] { values[key] = home.path }',
     'for key in ["HOME", "CFFIXED_USER_HOME", "ZDOTDIR"] { values[key] = configuration.agentHome.path }', LAUNCH),
    ('credential-file', PROCESS, '"cli_auth_credentials_store": "ephemeral"',
     '"cli_auth_credentials_store": "file"', LAUNCH),
    ('provider', PROCESS, '"model_provider": Self.provider', '"model_provider": "openai"', LAUNCH),
    ('parent-walk', PROCESS, '"project_root_markers": [String]()',
     '"project_root_markers": [".git"]', LAUNCH),
    ('instruction-files', PROCESS, '"project_doc_max_bytes": 0', '"project_doc_max_bytes": 32768', LAUNCH),
    ('shell-token', PROCESS, '"exclude": [Self.tokenVariable]', '"exclude": [String]()', LAUNCH),
    ('snapshot', PROCESS, '"features.shell_snapshot": false', '"features.shell_snapshot": true', LAUNCH),
    ('ephemeral', AGENT, '"ephemeral": true', '"ephemeral": false', LAUNCH),
    ('forbidden', PROCESS, 'if status == 403 { return .forbidden }', 'if status == 403 { return .unauthorized }', ERRORS),
    ('usage-limit', PROCESS, '|| status == 429', '|| status == 430', ERRORS),
    ('renewal', PROCESS, '_ = try tokens.reportRejected(token, requestShape: shape)', '_ = token', ERRORS),
    ('terminal-refresh', PROCESS, 'return Self.conversationError(error)', 'return .unavailable', ERRORS),
    ('approval-lifetime', AGENT,
     '      do {\n        // End every approval before a token renewal can block after transport teardown.\n        let approvals = ConversationApprovals(timeout: configuration.approvalTimeout) { continuation.yield($0) }',
     '      let approvals = ConversationApprovals(timeout: configuration.approvalTimeout) { continuation.yield($0) }\n      do {', ERRORS),
    ('request-shape', 'Sources/Outbound/ChatGPTSession.swift',
     'guard !record.requestRefused(requestShape)', 'guard !record.requestRefused(self.requestShape)', SCOPED),
    ('catalog-crash-home', AGENT, 'cleanupHome: launch.ownedHome, initial: [initial]',
     'cleanupHome: nil, initial: [initial]', 'AdapterTests/testHostSIGKILL'),
    ('turn-crash-home', AGENT, 'cleanupLease: runtime.lease, cleanupHome: launch.ownedHome',
     'cleanupLease: runtime.lease, cleanupHome: nil', 'AdapterTests/testHostSIGKILL'),
    ('stale-home-lock', 'Sources/Outbound/CodexProcessHome.swift',
     'flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }', 'true else { continue }', 'CodexHomeTests'),
    ('stale-home-age', 'Sources/Outbound/CodexProcessHome.swift',
     'now - Double(info.st_birthtimespec.tv_sec) > staleAge', 'now > 0', 'CodexHomeTests'),
    ('native-message-guess', PROCESS, 'let code = error["code"] as? String',
     'let code = (error["code"] as? String) ?? (error["message"] as? String)', 'CodexPlanFailureTests'),
    ('account-models', AGENT, 'choices.compactMap { choice in',
     'models.compactMap { choice in', 'AdapterTests/testAccountCatalog'),
    ('models-visibility', 'Sources/Outbound/ChatGPTModels.swift',
     '$0["visibility"] as? String == "list"', '_ in true', 'ChatGPTModelsTests'),
    ('models-bearer', 'Sources/Outbound/ChatGPTModels.swift',
     '"Bearer " + token.value', '"Bearer invented-wrong"', 'ChatGPTModelsTests'),
    ('models-account-switch', AGENT, 'guard try access(shape) == token',
     'guard true', 'AdapterTests/testAccountCatalog'),
    ('picker-account-switch', 'Sources/Shell/ConversationController.swift',
     '(provider == .codex && catalogAccountGeneration != settings.connectionGeneration)',
     'false', 'ConversationScreenTests/testAccountSwitchAndSignInRefreshChoicesWhileConnected'),

]


def main():
    repo = pathlib.Path(sys.argv[1]).resolve()
    if pathlib.Path('/tmp').resolve() not in repo.parents or (repo / '.git').exists():
        raise SystemExit('An expendable temporary copy without .git is required.')
    chosen = set(sys.argv[2:])
    baseline = subprocess.run(['swift', 'test', '--jobs', '1', '--filter', LAUNCH + '|' + ERRORS + '|' + SCOPED + '|AdapterTests/testHostSIGKILL|CodexHomeTests|ChatGPTModelsTests|AdapterTests/testAccountCatalog|ConversationScreenTests/testAccountSwitch'],
                              cwd=repo, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (repo.parent / 'codex-mutation-baseline.log').write_text(baseline.stdout)
    if baseline.returncode != 0:
        raise SystemExit('Unmodified conversation tests must pass before mutation checks.')
    print('baseline: passed', flush=True)
    for name, relative, before, after, selected in MUTATIONS:
        if chosen and name not in chosen:
            continue
        path = repo / relative
        original = path.read_bytes()
        text = original.decode()
        if text.count(before) != 1:
            raise SystemExit(f'{name}: mutation anchor must occur exactly once')
        try:
            path.write_text(text.replace(before, after))
            result = subprocess.run(['swift', 'test', '--jobs', '1', '--filter', selected],
                                    cwd=repo, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            (repo.parent / f'codex-mutation-{name}.log').write_text(result.stdout)
            if result.returncode == 0 or 'Build complete!' not in result.stdout or 'Test Suite' not in result.stdout or 'failed' not in result.stdout:
                raise SystemExit(f'{name}: tests did not reject the built mutation ({result.returncode})')
            print(f'{name}: rejected', flush=True)
        finally:
            path.write_bytes(original)
    print('all mutations rejected', flush=True)


if __name__ == '__main__':
    main()
