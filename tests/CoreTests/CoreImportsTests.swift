import Foundation
import XCTest

final class CoreImportsTests: XCTestCase {
  func testCoreSourcesAndImportSyntax() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    // Exercise the build checker itself so a second parser cannot disagree with it.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-B", root.appendingPathComponent("Plugins/ImportBoundary/test_check.py").path]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "Core sources and import syntax checks must pass")
  }
}
