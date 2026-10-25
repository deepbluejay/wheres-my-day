import Foundation

/// Shared launch identities for the window shell and the log readers.
public enum AgentWindowIdentity {
  public static let codexOriginator = "activityprobe_window"
  /// Matches the app name registered by Sign in with ChatGPT.
  public static let codexPlanOriginator = "ActivityProbe"
  public static let relativeFolder = "Library/Application Support/ActivityProbe/agent-window"

  public static func containsWorkingFolder(_ path: String) -> Bool {
    guard path.hasPrefix("/") else { return false }
    let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    let own = relativeFolder.split(separator: "/").map(String.init)
    guard parts.count >= own.count else { return false }
    return (0...(parts.count - own.count)).contains { index in
      Array(parts[index..<(index + own.count)]) == own
    }
  }
}
