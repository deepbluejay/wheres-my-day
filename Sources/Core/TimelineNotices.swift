import Foundation

public enum TimelinePermission: String, CaseIterable { case accessibility, inputMonitoring, screenRecording }
public enum TimelineNoticeKind: String, CaseIterable {
  case accessibility, inputMonitoring, screenRecording, subscription
  case fileVaultOff, fileVaultUnknown, backupExclusion, summaryFailure, summaryPreparation, summaryPaused
}
public enum TimelineNoticeTarget: String { case settings }
public struct TimelineNotice: Equatable {
  public let kind: TimelineNoticeKind
  /// A one-line fallback; the shell localizes by kind.
  public let line: String
  public let target: TimelineNoticeTarget
}
public struct TimelineHealth {
  public var missingPermissions: Set<TimelinePermission>
  public var security: DeviceSecurityHealth
  /// nil means no summary health snapshot yet; the persisted connection setting still applies.
  /// The shell must fill the snapshot's subscriptionConnected from the current connection state.
  public var summary: SummaryHealth?
  /// The ChatGPT sign-in as the window last read it; nil when not read. Summaries use Claude, so it no
  /// longer pauses them.
  public var chatGPT: ChatGPTConnectionStatus?
  public init(missingPermissions: Set<TimelinePermission> = [], security: DeviceSecurityHealth = DeviceSecurityHealth(),
    summary: SummaryHealth? = nil, chatGPT: ChatGPTConnectionStatus? = nil) {
    self.missingPermissions = missingPermissions; self.security = security; self.summary = summary; self.chatGPT = chatGPT
  }
}

public enum TimelineNotices {
  public static let deferredSettingKey = "timeline.deferredNotices"

  private static func deferred(in settings: StorageSettings) -> Set<String> {
    guard let value = settings.general[deferredSettingKey],
      let values = try? JSONDecoder().decode([String].self, from: Data(value.utf8)) else { return [] }
    return Set(values)
  }

  /// The caller persists these settings through SettingsStore, using one existing table value.
  public static func deferNotice(_ kind: TimelineNoticeKind, in settings: inout StorageSettings) {
    var values = deferred(in: settings)
    values.insert(kind.rawValue)
    let data = try! JSONEncoder().encode(values.sorted())
    settings.general[deferredSettingKey] = String(decoding: data, as: UTF8.self)
  }

  public static func make(settings: StorageSettings, health: TimelineHealth) -> [TimelineNotice] {
    let missing = problems(settings: settings, health: health)
    let hidden = deferred(in: settings)
    return TimelineNoticeKind.allCases.filter { missing.contains($0) && !hidden.contains($0.rawValue) }.map {
      TimelineNotice(kind: $0, line: line(for: $0), target: .settings)
    }
  }

  /// Returns settings for the shell to save when a deferred problem has gone away.
  /// A later recurrence is visible again; problems still present remain deferred.
  /// Read missingPermissions and security freshly before calling. An unread summary
  /// snapshot preserves summary deferrals until its problems can be checked.
  public static func resolved(settings: StorageSettings, health: TimelineHealth) -> StorageSettings? {
    let hidden = deferred(in: settings)
    var unresolved = problems(settings: settings, health: health)
    if health.summary == nil { unresolved.formUnion([.summaryFailure, .summaryPreparation, .summaryPaused]) }
    let remaining = hidden.intersection(unresolved.map(\.rawValue))
    guard remaining != hidden else { return nil }
    var settings = settings
    let data = try! JSONEncoder().encode(remaining.sorted())
    settings.general[deferredSettingKey] = String(decoding: data, as: UTF8.self)
    return settings
  }

  private static func problems(settings: StorageSettings, health: TimelineHealth) -> Set<TimelineNoticeKind> {
    var missing = Set<TimelineNoticeKind>()
    for permission in health.missingPermissions { missing.insert(TimelineNoticeKind(rawValue: permission.rawValue)!) }
    // Summaries use Claude: Claude use must be on and the last pass must have found the login.
    if !settings.claudeConnected || health.summary?.subscriptionConnected == false { missing.insert(.subscription) }
    switch health.security.fileVault {
    case .on: break
    case .off: missing.insert(.fileVaultOff)
    case .unknown: missing.insert(.fileVaultUnknown)
    }
    if health.security.backupExclusionFailure != nil { missing.insert(.backupExclusion) }
    if health.summary?.failedRanges.isEmpty == false { missing.insert(.summaryFailure) }
    if health.summary?.localPreparationFailed == true { missing.insert(.summaryPreparation) }
    if settings.claudeConnected && health.summary?.planUsePaused == true { missing.insert(.summaryPaused) }
    return missing
  }

  private static func line(for kind: TimelineNoticeKind) -> String {
    switch kind {
    case .accessibility: return "Accessibility permission is missing."
    case .inputMonitoring: return "Input Monitoring permission is missing."
    case .screenRecording: return "Screen Recording permission is missing."
    case .subscription: return "Connect your subscription to summarize activity."
    case .fileVaultOff: return "FileVault is off."
    case .fileVaultUnknown: return "FileVault status could not be checked."
    case .backupExclusion: return "Activity storage could not be excluded from backups."
    case .summaryFailure: return "Some activity could not be summarized."
    case .summaryPreparation: return "The summary connection could not be prepared."
    case .summaryPaused: return "Summaries are paused. Settings shows why."
    }
  }
}
