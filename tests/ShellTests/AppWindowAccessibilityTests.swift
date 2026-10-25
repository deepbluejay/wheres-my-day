import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Shell

final class AppWindowAccessibilityTests: XCTestCase {
  // Ideal: all four icon buttons have unique bounded native names, with no unlabeled image control.
  @MainActor func testNativeWindowControlsHaveActionNames() {
    let labels: [(String, String, String)] = [
      ("bubble.left.and.bubble.right", "Show conversation", "window.conversation"),
      ("gearshape", "Settings", "window.settings"),
      ("square.and.pencil", "New conversation", "window.new"),
      ("xmark", "Close conversation", "window.closePanel")]
    for (symbol, label, identity) in labels {
      let host = NSHostingView(rootView: AppWindowIcon(symbol: symbol, label: label, identity: identity, action: {}))
      host.frame = NSRect(x: 0, y: 0, width: 40, height: 40); host.layoutSubtreeIfNeeded()
      func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
      guard let button = buttons(host).first else { XCTFail("Missing native control"); continue }
      let name = button.accessibilityLabel() ?? ""
      XCTAssertTrue(name.hasPrefix(label)); XCTAssertTrue(name.contains(identity))
      XCTAssertLessThanOrEqual(name.unicodeScalars.count, 240); XCTAssertLessThanOrEqual(name.utf8.count, 960)
      XCTAssertEqual(button.accessibilityHelp(), label)
    }
  }
  // Ideal: every new control and status remains available in every supported language.
  func testAllWindowLabelsHaveNineCatalogLanguages() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("Resources/Localizable.xcstrings"))
    let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let keys = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
    for label in AppWindowLabel.allCases {
      let entry = try XCTUnwrap(keys[label.rawValue])
      XCTAssertNotEqual(entry["extractionState"] as? String, "stale")
      let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
      for language in ["ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"] {
        let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
        XCTAssertFalse((unit?["value"] as? String ?? "").isEmpty, "Missing translated window label")
      }
    }
  }
}
