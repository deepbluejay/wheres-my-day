import AppKit

/// The only AppKit call a process makes about its own Dock presence.
@MainActor public protocol ActivationPolicyTarget: AnyObject {
  @discardableResult func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool
}

extension NSApplication: ActivationPolicyTarget {}

/// One bundle runs several processes. Only the window/menu process is in the Dock and Cmd+Tab.
/// `LSUIElement` stays true, so every process starts hidden and only the window turns itself visible.
/// The recorder is registered with LaunchServices by its capture APIs, so a visible default would
/// put it in the Dock; and asking AppKit for a hidden policy would register every command too.
public enum ProcessPresentation: Equatable {
  /// Dock icon, Cmd+Tab and the menu bar icon.
  case dock
  /// No Dock icon and no menu: the recorder, every command and the query helper.
  case background

  /// Pure: decided from the arguments alone, before any path, window or status item exists.
  public static func mode(arguments: [String]) -> ProcessPresentation {
    var remaining: [String] = [], index = 0
    while index < arguments.count {
      if ["--isolated-root", "--app-data"].contains(arguments[index]) { index += 2 } else { remaining.append(arguments[index]); index += 1 }
    }
    return remaining == ["menu-bar"] || remaining == AppWindowReopen.arguments || AppWindowTarget(arguments: remaining) != nil ? .dock : .background
  }

  /// Background never asks for the application object, so it cannot connect or register anything.
  @MainActor public func apply(to application: () -> ActivationPolicyTarget) {
    guard self == .dock else { return }
    application().setActivationPolicy(.regular)
  }
}
