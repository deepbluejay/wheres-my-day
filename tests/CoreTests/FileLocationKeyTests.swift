import Foundation
import XCTest
@testable import Core

final class FileLocationKeyTests: XCTestCase {
  func testKeyFollowsParentIdentityAcrossCreationAliasAndRename() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-file-location-tests").appendingPathComponent(UUID().uuidString)
    let parent = root.appendingPathComponent("Parent"), renamed = root.appendingPathComponent("Renamed")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = parent.appendingPathComponent("future.sqlite")
    let before = try FileLocation.key(file)
    try Data().write(to: file)
    XCTAssertEqual(before, try FileLocation.key(file))
    let alias = root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
    XCTAssertEqual(before, try FileLocation.key(alias.appendingPathComponent("future.sqlite")))
    try FileManager.default.moveItem(at: parent, to: renamed)
    XCTAssertEqual(before, try FileLocation.key(renamed.appendingPathComponent("future.sqlite")))
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    XCTAssertNotEqual(before, try FileLocation.key(file))
    XCTAssertNotEqual(before, try FileLocation.key(renamed.appendingPathComponent("different.sqlite")))
    XCTAssertThrowsError(try FileLocation.key(parent.appendingPathComponent("missing/future.sqlite")))
  }

  // Ideal: equivalent names share bytes, while case-sensitive names remain independent.
  func testVolumeNameNormalization() {
    func bytes(_ name: String, sensitive: Bool) -> Data {
      Data(FileLocation.normalizedName(name, caseSensitive: sensitive).utf8)
    }
    XCTAssertEqual(bytes("Caf\u{e9}.sqlite", sensitive: false), bytes("cAFE\u{301}.SQLITE", sensitive: false))
    XCTAssertEqual(bytes("Caf\u{e9}.sqlite", sensitive: true), bytes("Cafe\u{301}.sqlite", sensitive: true))
    XCTAssertNotEqual(bytes("Future.sqlite", sensitive: true), bytes("future.sqlite", sensitive: true))
    XCTAssertNotEqual(bytes("first.sqlite", sensitive: false), bytes("second.sqlite", sensitive: false))
  }
}
