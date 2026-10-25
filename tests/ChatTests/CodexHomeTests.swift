import Core
import Darwin
import Foundation
@testable import Outbound
import XCTest

final class CodexHomeTests: XCTestCase {
  func testStaleSweepRequiresOwnedMarkerAgeAndUnlockedHome() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("codex-homes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let active = try CodexProcessHome(root: root)
    let stale = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.copyItem(at: active.url, to: stale)
    let unmarked = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let ordinary = root.appendingPathComponent("invented-unowned")
    try FileManager.default.copyItem(at: stale, to: ordinary)
    let link = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: stale)
    CodexProcessHome.sweep(root: root)
    XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path), "young homes remain")
    CodexProcessHome.sweep(root: root, now: Date().timeIntervalSince1970 + CodexProcessHome.staleAge + 10)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    for path in [active.url, unmarked, ordinary] { XCTAssertTrue(FileManager.default.fileExists(atPath: path.path)) }
    var info = stat()
    XCTAssertEqual(lstat(link.path, &info), 0, "symlinks are never swept")
    withExtendedLifetime(active) {}
  }
}
