import Foundation

enum ConversationDiagnostics {
  // Stable features that attach the account's connected apps and remote plugins, or drive a browser or the Mac.
  // Neither the in-app conversation nor a summary may have them; with apps on, the app-server also lists a
  // second MCP server, which the conversation wire refuses.
  static let codexFeaturesOff = ["apps", "plugins", "remote_plugin", "browser_use", "browser_use_external",
    "in_app_browser", "computer_use"]
  // These are CLI configuration overrides, including catalog and metadata processes.
  // Disabling the tool sandbox's network does not disable the parent CLI's exporters.
  static let codexSettings: [String: Any] = [
    "otel.log_user_prompt": false, "otel.log_agent_responses": false,
    "otel.log_guardian_assessments": false, "otel.tool_result.max_bytes": 0,
    "otel.exporter": "none", "otel.trace_exporter": "none", "otel.metrics_exporter": "none",
    "analytics.enabled": false, "feedback.enabled": false,
  ].merging(codexFeaturesOff.map { ("features." + $0, false as Any) }) { _, off in off }
  static let contentOff: [String: String] = [
    "CLAUDE_CODE_ENABLE_TELEMETRY": "0", "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "0",
    "ENABLE_ENHANCED_TELEMETRY_BETA": "0", "CLAUDE_CODE_PROPAGATE_TRACEPARENT": "0",
    "OTEL_LOG_USER_PROMPTS": "0", "OTEL_LOG_ASSISTANT_RESPONSES": "0",
    "OTEL_LOG_TOOL_CONTENT": "0", "OTEL_LOG_TOOL_DETAILS": "0", "OTEL_LOG_RAW_API_BODIES": "0",
    "OTEL_LOG_MANAGED_SETTINGS": "0", "OTEL_LOGS_EXPORTER": "none", "OTEL_TRACES_EXPORTER": "none",
    "OTEL_METRICS_EXPORTER": "none",
    "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
    "DEBUG": "0", "RUST_LOG": "off",
  ]
  // Claude fetches the claude.ai account's connectors for a subscription login. Servers given with
  // --mcp-config are unaffected by either switch.
  static let claudeConnectorsOff = ["ENABLE_CLAUDEAI_MCP_SERVERS": "false"]
  // --settings overrides user env blocks too; managed policy may override it.
  // Managed-policy precedence is not validated here.
  static var claudeSettings: [String: Any] {
    ["env": contentOff.merging(claudeConnectorsOff) { _, off in off }, "disableClaudeAiConnectors": true]
  }

  static func environment(_ inherited: [String: String]) -> [String: String] {
    var result = inherited.filter { key, _ in
      !key.hasPrefix("OTEL_") && !key.hasPrefix("SENTRY_") && !key.hasPrefix("DD_")
        && !key.hasPrefix("BETA_TRACING_")
        && !key.hasPrefix("CODEX_TRACE") && !key.hasPrefix("CODEX_OTEL")
        && !key.hasPrefix("CLAUDE_CODE_OTEL") && !key.hasPrefix("CLAUDE_CODE_DEBUG")
        && !["RUST_LOG", "RUST_BACKTRACE", "RUST_LIB_BACKTRACE", "LOG_FORMAT", "DEBUG",
          "ACTIVITYPROBE_CHATGPT_ACCESS_TOKEN", "NODE_DEBUG", "NODE_OPTIONS", "TRACEPARENT", "TRACESTATE"].contains(key)
    }
    result.merge(contentOff) { _, enforced in enforced }
    result.merge(claudeConnectorsOff) { _, enforced in enforced }
    return result
  }
}
