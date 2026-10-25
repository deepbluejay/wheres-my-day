import Core
import Foundation
import Shell

// Invented values only. No storage, connector, OS permission read or action is instantiated.
@main struct SettingsRenderTool {
  @MainActor static func main() throws {
    guard CommandLine.arguments.count == 3 else {
      fputs("usage: SettingsRender OUTPUT_DIRECTORY COMPILED_RESOURCES_DIRECTORY\n", stderr); exit(2)
    }
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    let resources = URL(fileURLWithPath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let languages = ["en", "ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"]
    var rendered = 0
    for language in languages {
      for (name, dark, width, connected, problem, missing) in [
        ("light", false, 720.0, false, false, false),
        ("dark", true, 720.0, true, false, false),
        ("problem", false, 720.0, true, true, false),
        ("permission", false, 720.0, true, false, true),
        ("narrow", false, 360.0, false, false, true),
        ("expired", false, 360.0, false, false, false),
        ("override", false, 360.0, false, false, false),
        ("status-timeout", false, 360.0, false, false, false),
        ("retention-conflict", false, 360.0, false, false, false),
        ("backup-failed", false, 360.0, false, false, false),
        ("superseded", false, 360.0, false, false, false),
        ("plan-required", false, 360.0, false, false, false),
        ("sign-in-again", true, 360.0, false, false, false),
        ("paused-no-sign-in", false, 720.0, true, false, false),
        ("paused-sign-in-again", false, 360.0, true, true, false),
        ("usage-limited", false, 720.0, true, false, false),
        ("not-accepted", true, 360.0, true, false, false),
        ("request-refused", false, 720.0, true, false, false),
        ("service-unavailable", false, 360.0, true, false, false),
        ("switch-kept", false, 360.0, true, false, false),
        ("unavailable", false, 360.0, false, false, false),
        ("summaries-off", true, 720.0, false, false, false),
        ("different-account", false, 360.0, false, false, false)
      ] {
        let settings = StorageSettings(excludedApps: ["org.example.invented"], pausedUntil: name == "expired" ? 1799990000 : 1800001800,
          subscriptionConnected: connected, screenRetentionDays: 30, promptRetentionDays: 14,
          general: ["dayStartHour": "4"])
        var summary = SummaryHealth(); summary.subscriptionConnected = connected; summary.localPreparationFailed = problem
        if name == "service-unavailable" { summary.planUsePaused = true; summary.serviceUnavailableUntil = 1800000300 }
        var security = DeviceSecurityHealth(); security.fileVault = missing ? .off : .on
        if missing || name == "backup-failed" { security.backupExclusionFailure = .backupExclusionFailed }
        if name == "override" { security.backupExclusionFailure = .backupExclusionSkippedOverride }
        let health = TimelineHealth(missingPermissions: missing ? [.screenRecording] : [], security: security, summary: summary)
        let model = SettingsViewModel(settings: settings, health: health, ownBundleID: "org.example.self", now: 1800000000)
        var draft = SettingsRetentionDraft(StorageSettings(screenRetentionDays: 21, promptRetentionDays: 7))
        draft.screen = "17"; draft.receive(settings)
        let error: SettingsMessage? = problem ? .preparation : name == "status-timeout" ? .statusTimeout : name == "superseded" ? .connectionSuperseded
          : name == "plan-required" ? .chatGPTPlanRequired : name == "different-account" ? .chatGPTDifferentAccount
          : name == "switch-kept" ? .chatGPTDifferentAccountWithoutPlan : nil
        let paused = name.hasPrefix("paused")
        let status: ChatGPTConnectionStatus = paused ? (problem ? .signInAgain : .notConnected)
          : name == "usage-limited" ? .usageLimited : name == "not-accepted" ? .notAccepted
          : name == "request-refused" ? .requestRefused
          : connected || name == "summaries-off" ? .connected : name == "plan-required" ? .planRequired
          : name == "sign-in-again" ? .signInAgain : name == "unavailable" ? .unavailable : .notConnected
        let chatGPT = ChatGPTAccountOverview(status: status, registered: status != .notConnected || name == "different-account")
        guard let png = SettingsOffscreenRender.png(model: model, strings: SettingsStrings(language: language, resources: resources),
          width: width, dark: dark, apps: [SettingsApp(id: "org.example.invented", name: "Example"),
            SettingsApp(id: "org.example.other", name: "Example 2")], error: error, draft: name == "retention-conflict" ? draft : nil,
            chatGPT: chatGPT) else { exit(1) }
        rendered += 1
        try png.write(to: output.appendingPathComponent(language + "-" + name + ".png"))
      }
      for (name, account, enabled, uncertain, width) in [
        ("claude-plan-on", ClaudeLoginSnapshot(state: .loggedIn, email: "person@example.com", plan: "Max"), true, false, 720.0),
        ("claude-plan-off", ClaudeLoginSnapshot(state: .loggedIn, email: "person@example.com", plan: "Pro"), false, false, 360.0),
        ("claude-no-plan", ClaudeLoginSnapshot(state: .loggedIn, email: "person@example.com"), false, false, 720.0),
        ("claude-no-email", ClaudeLoginSnapshot(state: .loggedIn, plan: "Team"), true, false, 360.0),
        ("claude-logged-out", ClaudeLoginSnapshot(state: .loggedOut), false, false, 720.0),
        ("claude-folder-unknown", ClaudeLoginSnapshot(state: .loggedIn, email: "person@example.com", plan: "Enterprise"), true, true, 360.0)
      ] {
        let settings = StorageSettings(general: ["chat.claude.connected": enabled ? "1" : "0"])
        let model = SettingsViewModel(settings: settings, health: TimelineHealth(), ownBundleID: "org.example.self", now: 1800000000)
        guard let png = SettingsOffscreenRender.png(model: model, strings: SettingsStrings(language: language, resources: resources),
          width: width, dark: false, claudeAccount: account, claudeFolderUncertain: uncertain) else { exit(1) }
        try png.write(to: output.appendingPathComponent(language + "-" + name + ".png"))
        rendered += 1
      }
      for dark in [false, true] {
        guard let png = SettingsOffscreenRender.planWelcomePNG(strings: SettingsStrings(language: language, resources: resources), dark: dark)
        else { exit(1) }
        rendered += 1
        try png.write(to: output.appendingPathComponent(language + "-plan-welcome" + (dark ? "-dark" : "") + ".png"))
      }
    }
    print("\(rendered) invented settings PNGs rendered without windows or system actions")
  }
}
