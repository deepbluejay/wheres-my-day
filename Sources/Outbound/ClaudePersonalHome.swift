import Core
import Foundation

/// Claude Code runs as the person's own install: their HOME, their login and, only when their login
/// shell sets one, their CLAUDE_CONFIG_DIR. The app never logs in, and never reads or stores a token;
/// the CLI reads its own login in its own process.
public struct ClaudePersonalHome: Equatable {
  public let userHome: URL
  /// From the person's login shell. nil leaves the CLI on its default folder.
  public let configOverride: String?
  public init(userHome: URL, configOverride: String?) {
    self.userHome = userHome; self.configOverride = configOverride
  }
  public var configDirectory: URL {
    configOverride.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? userHome.appendingPathComponent(".claude", isDirectory: true)
  }
  /// Without CLAUDE_CONFIG_DIR the CLI keeps its global configuration beside its folder, in the home.
  public var globalConfiguration: URL {
    configOverride == nil ? userHome.appendingPathComponent(".claude.json") : configDirectory.appendingPathComponent(".claude.json")
  }
  /// The file the CLI falls back to when it cannot use the keychain.
  public var credentials: URL { configDirectory.appendingPathComponent(".credentials.json") }
  /// The person's settings can hold keys in their environment or a command that prints one, and the global
  /// configuration names the account. The CLI reads them in its own process. Copies of the global configuration
  /// count too: the CLI's rotating backups folder, its legacy `.config.json`, and an older CLI's backup in the home.
  /// The config folder itself stays readable.
  public var settings: [URL] {
    [configDirectory.appendingPathComponent("settings.json"), configDirectory.appendingPathComponent("settings.local.json"), globalConfiguration,
      configDirectory.appendingPathComponent("backups", isDirectory: true), configDirectory.appendingPathComponent(".config.json"),
      userHome.appendingPathComponent(".claude.json.backup")]
  }

  /// Every Claude child's environment. HOME, CFFIXED_USER_HOME, ZDOTDIR, TMPDIR and XDG_* are left as
  /// inherited: with an app-only home macOS finds no keychain and the person's login is not the one used.
  /// Inherited CLAUDE_*, ANTHROPIC_* and other agents' variables are dropped, so an API key, token or a
  /// config folder of the app's own launch never replaces the person's login.
  static func environment(_ inherited: [String: String], configOverride: String?) -> [String: String] {
    var values = ConversationDiagnostics.environment(inherited.filter { key, _ in
      !["CODEX_", "CLAUDE_", "ANTHROPIC_", "OPENAI_", "GIT_"].contains(where: key.hasPrefix)
    })
    for key in ["BASH_ENV", "ENV", "CLAUDECODE"] { values.removeValue(forKey: key) }
    values["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
    if let configOverride { values["CLAUDE_CONFIG_DIR"] = configOverride }
    return values
  }
}
