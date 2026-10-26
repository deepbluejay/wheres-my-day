import Core
import Darwin
import Foundation

/// Recorded screen text reaches the conversation, so a prompt injection could ask the agent's own
/// tools to read a login file and send it. Each CLI reads its own login in its own process, outside
/// the tool rules and sandbox set here. Approvals and skip-approvals both keep these denials.
extension ConversationConfiguration {
  static let codexProfile = "activityprobe-conversation"
  static let codexOpenProfile = "activityprobe-conversation-open"

  /// The homes may sit under /tmp or /var, which macOS resolves to /private. Deny both spellings.
  static func spellings(_ url: URL) -> [String] {
    var result = [url.path]
    if let parent = realpath(url.deletingLastPathComponent().path, nil) {
      let resolved = URL(fileURLWithPath: String(cString: parent)).appendingPathComponent(url.lastPathComponent).path
      free(parent)
      if resolved != url.path { result.append(resolved) }
    }
    return result
  }

  /// The app's earlier Claude folder. Nothing creates it any more, but a login file from before may remain.
  var legacyClaudeHome: URL { appDataDirectory.appendingPathComponent("claude", isDirectory: true) }
  /// The person's own Claude Code, as each child finds it. The inherited HOME is added when it differs.
  func personalClaudeHomes(_ personal: ClaudePersonalHome) -> [ClaudePersonalHome] {
    var homes = [personal]
    if let home = inheritedEnvironment["HOME"], home.hasPrefix("/"), home != personal.userHome.path {
      homes.append(ClaudePersonalHome(userHome: URL(fileURLWithPath: home), configOverride: personal.configOverride))
    }
    return homes
  }
  /// The person's own Codex home: `$CODEX_HOME` as this process inherited it, and the default folder.
  var personalCodexHomes: [URL] {
    var homes = [userHome.appendingPathComponent(".codex")]
    if let home = inheritedEnvironment["CODEX_HOME"], home.hasPrefix("/"), home != homes[0].path { homes.append(URL(fileURLWithPath: home)) }
    return homes
  }
  var personalCodexLogins: [URL] { personalCodexHomes.map { $0.appendingPathComponent("auth.json") } }
  /// CLI settings no agent reads: the person's Claude settings and global configuration, and their Codex
  /// configuration, which can also carry keys or a command that prints one. Each CLI reads its own in its process.
  func personalSettings(_ personal: ClaudePersonalHome) -> [URL] {
    personalClaudeHomes(personal).flatMap(\.settings) + personalCodexHomes.map { $0.appendingPathComponent("config.toml") }
  }
  func keychains(_ personal: ClaudePersonalHome) -> [URL] {
    personalClaudeHomes(personal).map { $0.userHome.appendingPathComponent("Library/Keychains") }
  }
  /// The script the login button hands to Terminal, which runs it with the person's full rights.
  var claudeLoginFolder: URL { ClaudeLoginScript(appData: appDataDirectory).folder }
  private func unique(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }

  /// Closed to Claude's file tools and its sandbox: login files, the macOS keychain files, the person's CLI
  /// settings, the app's Codex home and its earlier Claude folder. Claude reads its own login in its own process.
  func claudeDeniedPaths(_ personal: ClaudePersonalHome) -> [String] {
    let homes = personalClaudeHomes(personal)
    return unique(([codexHome, legacyClaudeHome] + homes.map(\.credentials) + personalCodexLogins
      + keychains(personal) + personalSettings(personal)).flatMap(Self.spellings))
  }
  /// Codex needs its own home readable for its shell; its login files, Claude's folders, the keychain files
  /// and the person's CLI settings are closed.
  var codexDeniedPaths: [String] {
    let personal = ClaudePersonalHome(userHome: userHome, configOverride: command.claudeConfigDirectory())
    return unique(([legacyClaudeHome, codexHome.appendingPathComponent("auth.json"), codexHome.appendingPathComponent(".credentials.json")]
      + personalClaudeHomes(personal).map(\.configDirectory) + personalCodexLogins
      + keychains(personal) + personalSettings(personal)).flatMap(Self.spellings))
  }

  /// A file a later process runs outside the sandbox is as good as a read of the login file: the agent's
  /// shell startup files, sourced when a CLI snapshots its shell. Each CLI's own configuration is added below.
  var agentStartupFiles: [URL] { Self.startupFiles(in: agentHome) }
  static func startupFiles(in home: URL) -> [URL] {
    [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout", ".bashrc", ".bash_profile", ".bash_login", ".profile"]
      .map { home.appendingPathComponent($0) }
  }
  /// Git configuration in the agent's home can name commands, such as core.fsmonitor, that a CLI's own git
  /// calls run outside the sandbox. HOME and XDG_CONFIG_HOME both point into the agent home.
  var agentGitConfiguration: [URL] {
    [agentHome.appendingPathComponent(".gitconfig"), agentHome.appendingPathComponent("xdg_config_home/git")]
  }
  /// Claude starts in the person's home, so the same files are the person's own: their shell startup
  /// files (also under an inherited ZDOTDIR) and git configuration (also under an inherited XDG_CONFIG_HOME).
  func personalStartupFiles(_ personal: ClaudePersonalHome) -> [URL] {
    var files: [URL] = []
    for home in personalClaudeHomes(personal).map(\.userHome) {
      files += Self.startupFiles(in: home) + [home.appendingPathComponent(".gitconfig"), home.appendingPathComponent(".config/git")]
    }
    if let zdotdir = inheritedEnvironment["ZDOTDIR"], zdotdir.hasPrefix("/") { files += Self.startupFiles(in: URL(fileURLWithPath: zdotdir)) }
    if let xdg = inheritedEnvironment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") { files.append(URL(fileURLWithPath: xdg).appendingPathComponent("git")) }
    return files
  }
  /// Claude reloads settings, hooks and skills from its folder and the run folder's .claude while it runs,
  /// and the person's later sessions load them too. The CLI's own writes there are not tool calls. Codex
  /// still starts in the agent home, so its start-up files and git configuration stay closed to Claude too,
  /// and so does the login script Terminal runs.
  func claudeWriteProtectedPaths(work: URL, personal: ClaudePersonalHome) -> [String] {
    unique((personalClaudeHomes(personal).map(\.configDirectory) + [work.appendingPathComponent(".claude"), claudeLoginFolder,
        appDataDirectory.appendingPathComponent(AgentLogOwnSources.folderName)]
      + personalStartupFiles(personal)
      + agentStartupFiles + agentGitConfiguration).flatMap(Self.spellings))
  }
  /// A later Codex process starts what its home's configuration names outside the sandbox, and Terminal
  /// runs the login script with the person's rights.
  var codexWriteProtectedPaths: [String] {
    ([codexHome, claudeLoginFolder, appDataDirectory.appendingPathComponent(AgentLogOwnSources.folderName)] + agentStartupFiles + agentGitConfiguration).flatMap(Self.spellings)
  }
  /// Prefix rules only: a command that starts the tool another way passes them. The keychain files are
  /// closed in the sandbox as well; the keychain service itself is not a file the sandbox can close.
  static let claudeKeychainCommands = ["Bash(security *)", "Bash(/usr/bin/security *)"]

  /// Deny rules cover Claude's file tools and the file commands it recognises in Bash; the sandbox covers
  /// every process a Bash command starts. Deny rules also hold under --dangerously-skip-permissions, where
  /// the file tools are not sandboxed, so they also close the files Claude would run code from. Hooks are off
  /// for the same reason. The sandbox keeps Bash in the normal approval flow and has no unsandboxed retry.
  /// It may write the database and app data, as the deletion command needs; the denied paths stay closed inside them.
  /// The person's own settings, memory, plugins and instruction files stay out: auto memory is off and
  /// instruction files are limited to managed ones.
  func claudeConversationSettings(work: URL, personal: ClaudePersonalHome) -> [String: Any] {
    func rules(_ tools: [String], _ paths: [String]) -> [String] {
      paths.flatMap { path in tools.flatMap { tool in ["\(tool)(/\(path))", "\(tool)(/\(path)/**)"] } }
    }
    let denied = claudeDeniedPaths(personal)
    let protected = claudeWriteProtectedPaths(work: work, personal: personal)
    var writable: [String] = []
    for path in [appDataDirectory, database.deletingLastPathComponent()].flatMap(Self.spellings) where !writable.contains(path) {
      writable.append(path)
    }
    let sandbox: [String: Any] = ["enabled": true, "failIfUnavailable": true, "autoAllowBashIfSandboxed": false,
      "allowUnsandboxedCommands": false,
      "filesystem": ["denyRead": denied, "denyWrite": denied + protected, "allowWrite": writable]]
    return ConversationDiagnostics.claudeSettings.merging(["permissions": ["deny": rules(["Read", "Edit"], denied)
      + rules(["Edit"], protected) + Self.claudeKeychainCommands], "sandbox": sandbox, "disableAllHooks": true,
      "includeGitInstructions": false, "autoMemoryEnabled": false,
      "pluginConfigs": ["cc-plugin-agents-md@builtin": ["options": ["instructionFiles": "managed-only"]]]]) { _, fence in fence }
  }

  /// Codex can deny paths only through a permission profile, which replaces sandbox_mode. Skip-approvals
  /// keeps a sandbox that writes everywhere and reaches the network, instead of having no sandbox.
  /// In both, the paths it would run code from outside the sandbox are read-only; a deny inside them still wins.
  var codexPermissions: (profile: String, extends: String?, settings: [String: Any]) {
    var filesystem: [String: Any] = [:]
    for path in codexWriteProtectedPaths { filesystem[path] = "read" }
    for path in codexDeniedPaths { filesystem[path] = "deny" }
    // Codex walks up from the run folder to the nearest .git, without git, and loads every AGENTS.md and .codex
    // folder from there down. A skip-approvals agent could plant both above the run folder for every later
    // conversation. With no markers it reads only the run folder, which is new each time.
    let projectRoot: [String: Any] = ["project_root_markers": [String]()]
    if skipApprovals {
      filesystem[":root"] = "write"
      return (Self.codexOpenProfile, nil, projectRoot.merging(["default_permissions": Self.codexOpenProfile,
        "permissions": [Self.codexOpenProfile: ["filesystem": filesystem, "network": ["enabled": true]]]]) { _, fence in fence })
    }
    return (Self.codexProfile, ":workspace", projectRoot.merging(["default_permissions": Self.codexProfile,
      "permissions": [Self.codexProfile: ["extends": ":workspace", "filesystem": filesystem]]]) { _, fence in fence })
  }
}
