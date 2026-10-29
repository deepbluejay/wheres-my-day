import Core

/// What a window request asks for. Every command and the recorder decide their presentation with these,
/// so they live apart from the window-only files, where a scan of the recorder's sources sees them.
public enum AppWindowTarget: Equatable {
  case timeline, conversation, settings(SettingsSection)
  public init?(arguments: [String]) {
    switch arguments {
    case [], ["timeline"]: self = .timeline
    case ["agent-window"]: self = .conversation
    case ["settings"]: self = .settings(.recording)
    default:
      guard arguments.count == 2, arguments[0] == "settings", let section = SettingsSection(rawValue: arguments[1]) else { return nil }
      self = .settings(section)
    }
  }
  var line: String {
    switch self {
    case .timeline: return "timeline"
    case .conversation: return "agent-window"
    case .settings(let section): return "settings " + section.rawValue
    }
  }
  init?(line: String) {
    let arguments = line.split(separator: " ").map(String.init)
    guard !arguments.isEmpty else { return nil }
    self.init(arguments: arguments)
  }
}

/// Answer to a Dock click: an open window comes forward as it is; otherwise the timeline opens.
enum AppWindowReopen: Equatable {
  case focus
  case open(AppWindowTarget)
  /// An open of the app that reached the recorder comes to the window process as this request.
  static let line = "reopen"
  static let arguments = [line]
  static func route(windowOpen: Bool) -> AppWindowReopen { windowOpen ? .focus : .open(.timeline) }
}
