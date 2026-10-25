import Core

/// Paired retention fields keep their original base until saved or explicitly reloaded.
public struct SettingsRetentionDraft {
  public var screen: String
  public var prompt: String
  public private(set) var baseline: SettingsRetention
  public private(set) var conflicting = false
  public init(_ settings: StorageSettings) {
    baseline = SettingsRetention(settings)
    screen = String(baseline.screen); prompt = String(baseline.prompt)
  }
  public var dirty: Bool { screen != String(baseline.screen) || prompt != String(baseline.prompt) }
  public mutating func receive(_ settings: StorageSettings) {
    let latest = SettingsRetention(settings)
    if !dirty || (screen == String(latest.screen) && prompt == String(latest.prompt)) { self = Self(settings) }
    else { conflicting = latest != baseline }
  }
  public var edit: SettingsEdit { .retention(screen: Int(screen) ?? 0, prompt: Int(prompt) ?? 0, expected: baseline) }
}
