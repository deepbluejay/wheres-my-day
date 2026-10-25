import Core
import Foundation

/// The documented Sign in with ChatGPT provider. A process gets a new, empty Codex home;
/// its bearer exists only in the launch environment, never in configuration or a credential file.
final class CodexPlanProcess {
  static let tokenVariable = "ACTIVITYPROBE_CHATGPT_ACCESS_TOKEN"
  static let provider = "activityprobe_chatgpt_plan"
  let ownedHome: CodexProcessHome
  var home: URL { ownedHome.url }
  let executable: URL
  let environment: [String: String]
  let settings: [String: Any]
  init(configuration: ConversationConfiguration, token: ChatGPTAccessToken) throws {
    try configuration.prepare()
    let root = configuration.codexHome.appendingPathComponent("app-server")
    try AgentDirectories.prepare(appData: configuration.appDataDirectory, ownedDirectories: [root])
    ownedHome = try CodexProcessHome(root: root)
    let home = ownedHome.url
    do {
      // Global AGENTS.md has no off switch. This home has neither global instructions nor personal settings.
      try Data("project_root_markers = []\n".utf8).write(to: home.appendingPathComponent("config.toml"), options: .withoutOverwriting)
      let launch = try configuration.launch()
      executable = launch.executable
      var values = launch.environment
      values.removeValue(forKey: "CODEX_INTERNAL_ORIGINATOR_OVERRIDE")
      values["CODEX_HOME"] = home.path; values["CODEX_SQLITE_HOME"] = home.path
      // Skills can also come from HOME/.agents. Never reuse even the earlier app-only shell home.
      for key in ["HOME", "CFFIXED_USER_HOME", "ZDOTDIR"] { values[key] = home.path }
      values["TMPDIR"] = home.path
      for key in AgentDirectories.environmentFolders { values[key] = home.path }
      values[Self.tokenVariable] = token.value
      environment = values
      settings = ConversationDiagnostics.codexSettings.merging([
        "model_provider": Self.provider,
        "model_providers": [Self.provider: ["name": "ChatGPT plan", "base_url": "https://api.openai.com/v1",
          "env_key": Self.tokenVariable, "wire_api": "responses", "requires_openai_auth": false,
          "supports_websockets": false, "request_max_retries": 0, "stream_max_retries": 0]],
        "cli_auth_credentials_store": "ephemeral", "sqlite_home": home.path,
        "log_dir": home.appendingPathComponent("log").path,
        "project_root_markers": [String](), "project_doc_max_bytes": 0,
        "features.hooks": false, "features.memories": false,
        "features.shell_snapshot": false, "features.shell_snapshot_v2": false,
        "features.code_mode_only_strict_3p_tools": false,
        "history": ["persistence": "none"],
        "shell_environment_policy": ["exclude": [Self.tokenVariable]],
      ]) { _, enforced in enforced }
    } catch {
      try? FileManager.default.removeItem(at: home)
      throw (error as? ConversationError) ?? ConversationError.unavailable
    }
  }
}

/// Error values from app-server are inspected, never displayed or retained.
enum CodexPlanFailure: Error, Equatable {
  case unauthorized, forbidden, usageLimited, requestRefused, notEligible
  static func parse(_ error: [String: Any]) -> CodexPlanFailure? {
    let info = error["codexErrorInfo"] ?? (error["data"] as? [String: Any])?["codexErrorInfo"]
    let details = info as? [String: Any]
    let status = details?.values.compactMap { ($0 as? [String: Any])?["httpStatusCode"] as? Int }.first
      ?? error["httpStatusCode"] as? Int
    // Codex 0.163.0 drops unknown Responses codes in HTTP/SSE conversion. Never recover them
    // from display text: native 403 keeps the timed pause, and an unclassified stream fails plainly.
    let code = error["code"] as? String
    if code == "subscription_sharing_user_not_eligible" { return .notEligible }
    if code == "subscription_sharing_usage_limit_exceeded" { return .usageLimited }
    if info as? String == "unauthorized" || status == 401 { return .unauthorized }
    if status == 403 { return .forbidden }
    if ["usageLimitExceeded", "rateLimitExceeded"].contains(info as? String ?? "") || status == 429 { return .usageLimited }
    if info as? String == "badRequest" || status == 400 { return .requestRefused }
    return nil
  }
  static func conversationError(_ error: Error) -> ConversationError {
    guard let error = error as? ChatGPTTokenError else { return .unavailable }
    return [.notSignedIn, .planRequired, .notAvailable, .signInAgain].contains(error) ? .notLoggedIn : .unavailable
  }
  func report(tokens: ChatGPTAccessTokens, token: ChatGPTAccessToken, shape: String) -> ConversationError {
    switch self {
    // Never replay a turn automatically: tools may already have acted. The next turn starts with the replacement.
    case .unauthorized:
      do { _ = try tokens.reportRejected(token, requestShape: shape) }
      catch { return Self.conversationError(error) }
    case .forbidden: tokens.reportNotAccepted(token)
    case .usageLimited: tokens.reportUsageLimited(token)
    case .requestRefused: tokens.reportRequestRefused(token, requestShape: shape)
    case .notEligible: tokens.reportNotEligible(token); return .notLoggedIn
    }
    return .unavailable
  }
}
