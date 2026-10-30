import Core
import Foundation
@testable import Shell
import XCTest

/// The entry's window decision, `windowRequest`, called alone: it only parses paths, so no window opens.
final class EntryWindowDecisionTests: XCTestCase {
  // Ideal: the split entry sends to the window exactly what the unsplit one did, over a table of arguments.
  func testWindowDecisionMatchesTheUnsplitEntry() throws {
    let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("entry-window-\(UUID().uuidString)")
    let data = folder.appendingPathComponent("app-data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let home = folder.appendingPathComponent("home"), binary = folder.appendingPathComponent("bin/ActivityProbe")
    let isolated = ["--isolated-root", folder.path, "--app-data", data.path]
    let refused = ["--isolated-root", "/var/empty", "--app-data", data.path]
    var table: [[String]] = [[], ["timeline"], ["menu-bar"], ["reopen"], ["agent-window"], ["settings"], ["settings", "invented"],
      ["timeline", "extra"], ["reopen", "extra"], ["menu-bar", "extra"], ["agent-window", "extra"], ["collect"], ["stop"], ["status"],
      ["privacy", "mask"], ["privacy", "mask", "extra"], ["privacy", "forget", "1", "2"], ["privacy", "verdicts"], ["convert"],
      ["launch-agent", "install"], ["launch-agent"], ["selftest"], ["leaktest"], ["timeline", "--live-switch"], ["--live-switch"],
      ["invented"], [""], ["--isolated-root"], ["--app-data", data.path], ["Timeline"], ["settings", "Recording"]]
    table += SettingsSection.allCases.map { ["settings", $0.rawValue] }
    table += table.map { $0 + isolated } + table.map { isolated + $0 } + table.map { $0 + refused } + [isolated, ["collect", "extra"] + isolated]
    // What presents in the Dock, written out rather than asked of `ProcessPresentation.mode`, after the isolation pairs.
    let sections = ["recording", "exclusions", "retention", "dayStart", "subscription", "claude", "conversation", "permissions", "security",
    ]
    XCTAssertEqual(sections, SettingsSection.allCases.map(\.rawValue), "a new settings section belongs in this table")
    let dock: [[String]] = [[], ["timeline"], ["menu-bar"], ["reopen"], ["agent-window"], ["settings"]] + sections.map { ["settings", $0] }
    func withoutIsolation(_ arguments: [String]) -> [String] {
      var remaining: [String] = [], index = 0
      while index < arguments.count {
        if ["--isolated-root", "--app-data"].contains(arguments[index]) { index += 2 } else { remaining.append(arguments[index]); index += 1 }
      }
      return remaining
    }
    var windows = 0
    for environment in [[:], ["ACTIVITYPROBE_DB": folder.appendingPathComponent("invented.sqlite").path]] {
      for arguments in table {
        // The unsplit entry: launch-agent, convert, privacy mask and collect first, then a parse whose arguments are in
        // the Dock table. The parse only decides whether the paths are valid and what they are.
        var expected = "other"
        let remaining = withoutIsolation(arguments)
        if !["launch-agent", "convert", "collect"].contains(arguments.first ?? ""), arguments != ["privacy", "mask"],
          dock.contains(remaining),
          let parsed = try? ActivityProbeEntry.command(arguments: arguments, environment: environment, userHome: home, appBinary: binary) {
          expected = "window \(remaining) \(parsed.paths.database.path) \(parsed.paths.appData.path)"
        }
        let request = ActivityProbeEntry.windowRequest(arguments: arguments, environment: environment, userHome: home, appBinary: binary)
        let decided = request.map { "window \($0.arguments) \($0.paths.database.path) \($0.paths.appData.path)" } ?? "other"
        XCTAssertEqual(decided, expected, "\(arguments) \(environment.keys.sorted())")
        if decided != "other" { windows += 1 }
      }
    }
    XCTAssertGreaterThan(windows, 20)
    // The decision itself, independent of the table's own reading of it.
    func window(_ arguments: [String]) -> Bool {
      ActivityProbeEntry.windowRequest(arguments: arguments, environment: [:], userHome: home, appBinary: binary) != nil
    }
    for arguments in [[], ["timeline"], ["settings"], ["agent-window"], ["reopen"]] { XCTAssertTrue(window(arguments), "\(arguments)") }
    for arguments in [["collect"], ["stop"], ["status"], ["privacy", "mask"], ["privacy", "verdicts"], ["convert"], ["launch-agent"],
      ["selftest"], ["invented"]] { XCTAssertFalse(window(arguments), "\(arguments)") }
  }
}
