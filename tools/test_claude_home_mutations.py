#!/usr/bin/env python3
"""Prove the Claude-in-the-person's-home tests reject production mutations.

Run only against an expendable copy: python3 tools/test_claude_home_mutations.py /tmp/ap-.../repo [name ...]
Each mutation is applied alone, its tests are built and run, and the source is restored.
"""
import pathlib
import subprocess
import sys

DENY = 'AdapterTests/testBothEnginesDenyLoginFilesWithAndWithoutApprovals'
LAUNCH = 'AdapterTests/testBothAdaptersAndOwnSessions|AdapterTests/testSkipSettingChangesOnlyPermissionPolicy'
CONNECT = 'ClaudeConnectionTests/testStatusBeforeConsentAndIndependentSettings|ClaudeConnectionTests/testStrictCLIStatusRunsInThePersonsHome'
LOGIN = 'ClaudeConnectionTests/testTerminalLoginWritesAndOpensOnlyTheOfficialLogin'
SHELLS = 'AgentInstallTests/testSystemShellsAnswerPathAndExportedFolder'
FOLDER = 'AgentInstallTests/testClaudeFolderIsUnknownWithoutAnAbsoluteAnswer'
PAGE = 'ClaudeConnectionTests/testControllerChecksAndOpensThroughTheLoginSource'
VISIBLE = 'ClaudeConnectionTests/testClaudeLoginIsCheckedOnlyWhileItsSectionIsVisible'

MUTATIONS = [
    ('status-plan-map', 'Sources/Outbound/ClaudeSubscriptionConnector.swift',
     '"max": "Max"', '"max": "Pro"', 'ClaudeConnectionTests/testLoginStatusParsingPlansAndMissingFields'),
    ('status-email-dropped', 'Sources/Outbound/ClaudeSubscriptionConnector.swift',
     'email: nonempty("email")', 'email: nil', 'ClaudeConnectionTests/testLoginStatusParsingPlansAndMissingFields'),
    ('status-details-persisted', 'Sources/Outbound/ClaudeSubscriptionConnector.swift',
     'let plan = nonempty("subscriptionType")',
     'try? data.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"]!).appendingPathComponent("invented-status.json"))\n    let plan = nonempty("subscriptionType")',
     'ClaudeConnectionTests/testStatusDetailsHaveNoPersistenceOrDiagnosticSink'),
    ('config-dir-forced', 'Sources/Outbound/ClaudePersonalHome.swift',
     'if let configOverride { values["CLAUDE_CONFIG_DIR"] = configOverride }',
     'values["CLAUDE_CONFIG_DIR"] = configOverride ?? "/invented/app-claude"', CONNECT + '|' + LAUNCH),
    ('inherited-config-dir', 'Sources/Outbound/ClaudePersonalHome.swift',
     '!["CODEX_", "CLAUDE_", "ANTHROPIC_", "OPENAI_", "GIT_"]', '!["CODEX_", "ANTHROPIC_", "OPENAI_", "GIT_"]', CONNECT),
    ('auto-memory-env', 'Sources/Outbound/ClaudePersonalHome.swift',
     'values["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"', 'values["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "0"', CONNECT + '|' + DENY),
    ('app-home', 'Sources/Outbound/ConversationRuntime.swift',
     'var values = ClaudePersonalHome.environment(inheritedEnvironment, configOverride: personal.configOverride)',
     'var values = ClaudePersonalHome.environment(inheritedEnvironment, configOverride: personal.configOverride)'
     '.merging(AgentDirectories.environment(appData: appDataDirectory)) { _, app in app }', DENY + '|' + LAUNCH),
    ('legacy-folder-created', 'Sources/Outbound/ConversationRuntime.swift',
     'ownedDirectories: directories + [codexHome])', 'ownedDirectories: directories + [codexHome, legacyClaudeHome])',
     'IsolationTests/testAppPreparationDoesNotChangeSharedAncestorsOrTrustInheritedPaths|' + LAUNCH),
    ('setting-sources', 'Sources/Outbound/ClaudeConversationAgent.swift',
     '"--setting-sources", "",', '"--setting-sources", "user",', LAUNCH),
    ('slash-commands', 'Sources/Outbound/ClaudeConversationAgent.swift',
     '"--disable-slash-commands",', '', LAUNCH),
    ('session-persistence', 'Sources/Outbound/ClaudeConversationAgent.swift',
     '"--include-partial-messages", "--no-session-persistence",', '"--include-partial-messages",', LAUNCH),
    ('auto-memory-setting', 'Sources/Outbound/ConversationReadDenials.swift',
     '"autoMemoryEnabled": false', '"autoMemoryEnabled": true', DENY + '|' + LAUNCH),
    ('instruction-files', 'Sources/Outbound/ConversationReadDenials.swift',
     '"instructionFiles": "managed-only"', '"instructionFiles": "all"', DENY + '|' + LAUNCH),
    ('keychain-commands', 'Sources/Outbound/ConversationReadDenials.swift',
     '["Bash(security *)", ', '[', DENY + '|' + LAUNCH),
    ('keychain-files', 'Sources/Outbound/ConversationReadDenials.swift',
     'homes.map(\\.credentials) + personalCodexLogins\n      + keychains(personal) + ',
     'homes.map(\\.credentials) + personalCodexLogins\n      + ', DENY + '|' + LAUNCH),
    ('personal-settings-readable', 'Sources/Outbound/ConversationReadDenials.swift',
     'homes.map(\\.credentials) + personalCodexLogins\n      + keychains(personal) + personalSettings(personal))',
     'homes.map(\\.credentials) + personalCodexLogins\n      + keychains(personal))', DENY + '|' + LAUNCH),
    ('codex-config-readable', 'Sources/Outbound/ConversationReadDenials.swift',
     'flatMap(\\.settings) + personalCodexHomes.map { $0.appendingPathComponent("config.toml") }', 'flatMap(\\.settings)',
     DENY + '|' + LAUNCH),
    ('claude-backups-readable', 'Sources/Outbound/ClaudePersonalHome.swift',
     'configDirectory.appendingPathComponent("backups", isDirectory: true), ', '', DENY),
    ('claude-legacy-config-readable', 'Sources/Outbound/ClaudePersonalHome.swift',
     ', configDirectory.appendingPathComponent(".config.json"),', ',', DENY),
    ('claude-home-backup-readable', 'Sources/Outbound/ClaudePersonalHome.swift',
     ',\n      userHome.appendingPathComponent(".claude.json.backup")]', ']', DENY),
    ('claude-settings-readable', 'Sources/Outbound/ClaudePersonalHome.swift',
     '[configDirectory.appendingPathComponent("settings.json"), configDirectory.appendingPathComponent("settings.local.json"), globalConfiguration,',
     '[configDirectory.appendingPathComponent("settings.json"), globalConfiguration,', DENY),
    ('codex-keychain', 'Sources/Outbound/ConversationReadDenials.swift',
     'map(\\.configDirectory) + personalCodexLogins\n      + keychains(personal) + ',
     'map(\\.configDirectory) + personalCodexLogins\n      + ', DENY + '|' + LAUNCH),
    ('codex-personal-settings', 'Sources/Outbound/ConversationReadDenials.swift',
     'map(\\.configDirectory) + personalCodexLogins\n      + keychains(personal) + personalSettings(personal))',
     'map(\\.configDirectory) + personalCodexLogins\n      + keychains(personal))', DENY + '|' + LAUNCH),
    ('claude-agent-home', 'Sources/Outbound/ConversationReadDenials.swift',
     '\n      + agentStartupFiles + agentGitConfiguration).flatMap', ').flatMap', DENY + '|' + LAUNCH),
    ('claude-agent-git', 'Sources/Outbound/ConversationReadDenials.swift',
     '\n      + agentStartupFiles + agentGitConfiguration).flatMap', '\n      + agentStartupFiles).flatMap', DENY + '|' + LAUNCH),
    ('claude-login-folder-claude', 'Sources/Outbound/ConversationReadDenials.swift',
     '[work.appendingPathComponent(".claude"), claudeLoginFolder]', '[work.appendingPathComponent(".claude")]', DENY + '|' + LAUNCH),
    ('claude-login-folder-codex', 'Sources/Outbound/ConversationReadDenials.swift',
     '([codexHome, claudeLoginFolder] + agentStartupFiles', '([codexHome] + agentStartupFiles', DENY + '|' + LAUNCH),
    ('credentials-file', 'Sources/Outbound/ConversationReadDenials.swift',
     'homes.map(\\.credentials) + personalCodexLogins', 'personalCodexLogins', DENY + '|' + LAUNCH),
    ('codex-login', 'Sources/Outbound/ConversationReadDenials.swift',
     'homes.map(\\.credentials) + personalCodexLogins', 'homes.map(\\.credentials)', DENY + '|' + LAUNCH),
    ('claude-folder-writable', 'Sources/Outbound/ConversationReadDenials.swift',
     'unique((personalClaudeHomes(personal).map(\\.configDirectory) + [work', 'unique(([work', DENY + '|' + LAUNCH),
    ('personal-startup', 'Sources/Outbound/ConversationReadDenials.swift',
     '\n      + personalStartupFiles(personal)\n', '\n', DENY + '|' + LAUNCH),
    ('codex-personal-claude', 'Sources/Outbound/ConversationReadDenials.swift',
     '+ personalClaudeHomes(personal).map(\\.configDirectory) + personalCodexLogins', '+ personalCodexLogins',
     DENY + '|AdapterTests/testBothAdaptersAndOwnSessions'),
    ('app-runs-login', 'Sources/Outbound/ClaudeSubscriptionConnector.swift',
     'process.arguments = ["auth", "status", "--json"]', 'process.arguments = ["auth", "login", "--json"]', CONNECT),
    ('status-exit-mapping', 'Sources/Outbound/ClaudeSubscriptionConnector.swift',
     'exitCode == 1 ? .loggedOut : .unknown', '.loggedOut',
     'ClaudeConnectionTests/testLoginStateChecksExitCodeAndJSON'),
    ('login-script-flag', 'Sources/Outbound/ClaudeSubscriptionConnector.swift',
     '" auth login\\n"', '" auth login --claudeai\\n"', LOGIN),
    ('login-script-mode', 'Sources/Outbound/ClaudeSubscriptionConnector.swift',
     'fchmod(descriptor, 0o700)', 'fchmod(descriptor, 0o755)', LOGIN),
    ('login-opens-other', 'Sources/Outbound/ClaudeSubscriptionConnector.swift',
     'try await openTerminal(try loginScript.write(executable: install.executable))',
     '_ = try loginScript.write(executable: install.executable); try await openTerminal(loginScript.folder)', LOGIN),
    ('credential-read', 'Sources/Outbound/ClaudeSubscriptionConnector.swift',
     'public func openLogin() async throws {',
     'public func openLogin() async throws {\n    _ = try? Data(contentsOf: ClaudePersonalHome(userHome: userHome, configOverride: nil).credentials)',
     'ClaudeConnectionTests/testOnlyDenialsNameLoginFiles'),
    ('logged-out-generic', 'Sources/Outbound/ClaudeConversationAgent.swift',
     'exitErrors: [1: .notLoggedIn])', 'exitErrors: [:])', 'AdapterTests/testLoggedOutClaudeStopsBeforeTheConversation'),
    ('logged-out-message', 'Sources/Shell/ConversationController.swift',
     'self.history = previousHistory; self.error = selection.provider == .claude ? .claudeNotLoggedIn : .notConnected',
     'self.saveReply(); self.error = .turnFailed',
     'ConversationScreenTests/testLoggedOutClaudeSaysWhatToDo'),
    ('relative-config', 'Sources/Outbound/UserShell.swift',
     '.flatMap { $0.hasPrefix("/") ? $0 : nil }', '', 'AgentInstallTests/testShellAnswerCarriesTheClaudeFolder'),
    ('shell-folder-syntax', 'Sources/Outbound/UserShell.swift',
     "/usr/bin/printenv CLAUDE_CONFIG_DIR | /usr/bin/sed 's/^/\\(claudeMarker)/'",
     "printf '\\(claudeMarker)%s\\\\n' \\\"${CLAUDE_CONFIG_DIR-}\\\"", SHELLS),
    ('csh-login-option', 'Sources/Outbound/UserShell.swift',
     'if ["csh", "tcsh"].contains(name) { return ["-" + name, "-i", "-c", command] }', '', SHELLS),
    ('relative-folder-known', 'Sources/Outbound/UserShell.swift',
     'claudeConfigRelative: given != nil && claude == nil)', 'claudeConfigRelative: false)', FOLDER),
    ('silent-shell-folder-known', 'Sources/Outbound/UserShell.swift',
     'guard let found = shellAnswer(environment: environment) else { return false }',
     'guard let found = shellAnswer(environment: environment) else { return true }', FOLDER),
    ('connector-folder-known', 'Sources/Outbound/ClaudeSubscriptionConnector.swift',
     'public func loginFolderKnown() -> Bool { command.claudeConfigKnown() }', 'public func loginFolderKnown() -> Bool { true }', FOLDER),
    ('page-folder-uncertain', 'Sources/Shell/SettingsController.swift',
     'claudeLogin = snapshot.state; claudeFolderUncertain = !known', 'claudeLogin = snapshot.state', PAGE),
    ('shared-status-state', 'Sources/Outbound/ClaudeSubscriptionConnector.swift',
     'let result = try status(StatusRun(), display: true)',
     'let result = try status({ lock.lock(); defer { lock.unlock() }; return connection ?? StatusRun() }(), display: true)',
     'ClaudeConnectionTests/testDisplayCheckAndConnectKeepTheirOwnState'),
    ('check-while-hidden', 'Sources/Shell/SettingsController.swift',
     'guard claudeSectionVisible, let source = claudeLoginSource, !isCheckingClaude else { return }',
     'guard let source = claudeLoginSource, !isCheckingClaude else { return }', VISIBLE),
    ('check-every-report', 'Sources/Shell/SettingsController.swift',
     'let appeared = visible && !claudeSectionVisible', 'let appeared = visible', VISIBLE),
    ('terminal-failure-ignored', 'Sources/Shell/TerminalLogin.swift',
     'if failed == true { throw SubscriptionConnectionError.terminalFailed }', '', 'ClaudeConnectionTests/testTerminalOpenFailureIsReported'),
    ('terminal-resumes-twice', 'Sources/Shell/TerminalLogin.swift',
     'let pending = continuation; continuation = nil;', 'let pending = continuation;', 'ClaudeConnectionTests/testTerminalOpenFailureIsReported'),
    ('claude-log-exclusion', 'Sources/Inbound/AgentLogHomes.swift',
     'guard tool == .codex else { return true }', 'guard tool == .codex else { return !folder.contains("/.claude/") }',
     'IsolationTests/testSummaryHomeAndItsAliasesAreExcludedFromLogDiscovery'),
]


def main():
    repo = pathlib.Path(sys.argv[1]).resolve()
    temporary = pathlib.Path('/tmp').resolve()
    if temporary not in repo.parents or (repo / '.git').exists():
        raise SystemExit('An expendable temporary copy without .git is required.')
    chosen = set(sys.argv[2:])
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
            (repo.parent / f'mutation-{name}.log').write_text(result.stdout)
            if result.returncode == 0 or 'error:' not in result.stdout or 'Build complete!' not in result.stdout:
                raise SystemExit(f'{name}: tests did not reject the built mutation ({result.returncode})')
            print(f'{name}: rejected')
        finally:
            path.write_bytes(original)
    print('all mutations rejected')


if __name__ == '__main__':
    main()
