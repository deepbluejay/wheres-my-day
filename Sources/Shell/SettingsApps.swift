import AppKit
import Core
import Foundation
import UniformTypeIdentifiers

/// Discovery is explicit and runs only when the real settings host asks for it.
public struct MacSettingsAppCatalog: SettingsAppCatalog {
  public init() {}
  public func apps() -> [SettingsApp] {
    let files = FileManager.default
    let locations = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"),
      URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Applications/Utilities"),
      files.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    var bundles = locations.flatMap { (try? files.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
      .filter { $0.pathExtension == "app" }
    bundles += NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
    var names = [String: String]()
    for url in bundles {
      guard let bundle = Bundle(url: url), let identity = bundle.bundleIdentifier?.lowercased(),
        SettingsValidation.validIdentity(identity), names[identity] == nil else { continue }
      names[identity] = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? url.deletingPathExtension().lastPathComponent
    }
    return names.map { SettingsApp(id: $0.key, name: $0.value) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}

/// Invoked only by the explicit chooser action in a real settings host.
public struct MacSettingsAppChooser: SettingsAppChooser {
  public init() {}
  @MainActor public func chooseApp() async -> SettingsApp? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.applicationBundle]
    let response = await panel.begin()
    guard response == .OK, let url = panel.url else { return nil }
    return Self.app(at: url)
  }
  public static func app(at url: URL) -> SettingsApp? {
    guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
      SettingsValidation.validIdentity(id) else { return nil }
    return SettingsApp(id: id, name: (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent)
  }
}
