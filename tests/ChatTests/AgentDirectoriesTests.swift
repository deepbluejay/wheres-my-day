import Foundation
import Outbound
import XCTest

final class AgentDirectoriesTests: XCTestCase {
  func testAppDataGrantUsesDirectoryIdentityForEquivalentSpellings() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-agent-directories-tests").appendingPathComponent(UUID().uuidString)
    let app = root.appendingPathComponent("Caf\u{e9}App")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sensitive = try XCTUnwrap(app.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
    let variant = root.appendingPathComponent(sensitive ? "Cafe\u{301}App" : "cAFE\u{301}aPP")
    let home = variant.appendingPathComponent("agent-home")
    try AgentDirectories.prepare(appData: app, ownedDirectories: [home])
    XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("agent-home").path))
    let missing = root.appendingPathComponent("missing-app")
    XCTAssertThrowsError(try AgentDirectories.prepare(appData: missing, ownedDirectories: [root.appendingPathComponent("outside")]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
  }
}
