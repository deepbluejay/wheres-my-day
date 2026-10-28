import Core
import Foundation
import XCTest
@testable import Storage

/// Scoped proofs start from a copied template and a reused snapshot connection.
/// Their expectation and baseline must equal a freshly built one.
final class CollectionProofTemplateTests: XCTestCase {
  var folder: URL!
  override func setUpWithError() throws {
    folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
  private func open(_ name: String) throws -> ActivityStorage {
    try ActivityStorage(url: folder.appendingPathComponent(name), appDataDirectory: folder, databaseScope: .directory(folder))
  }
  private func expectationSchema(_ store: ActivityStorage, full: Bool = false) throws -> [String] {
    try store.locked {
      try store.connection.transaction(collectionFullBaseline: full) {
        var rows: [String] = []
        try store.connection.collectionMaintenanceProof!.expected.rows("SELECT type||'|'||name||'|'||tbl_name||'|'||COALESCE(sql,'') FROM sqlite_master ORDER BY name") {
          rows.append(SQLiteConnection.text($0, 0))
        }
        return rows
      }
    }
  }
  func testScopedExpectationHasTheSameSchemaAndTriggersAsAFullBuild() throws {
    let store = try open("invented.sqlite")
    let scoped = try expectationSchema(store), again = try expectationSchema(store)
    XCTAssertEqual(scoped, try expectationSchema(store, full: true))
    XCTAssertEqual(again, scoped)
    XCTAssertTrue(scoped.contains { $0.hasPrefix("trigger|ingestion_samples|") })
    XCTAssertTrue(scoped.contains { $0.hasPrefix("table|proof_external_refs|") })
  }
  func testEachSourceSchemaGetsItsOwnTemplate() throws {
    let plain = try open("invented-plain.sqlite"), indexed = try open("invented-indexed.sqlite")
    try indexed.connection.run("CREATE INDEX invented_extra ON samples(app)")
    // Build the plain template first, then the changed schema, then the plain one again.
    XCTAssertFalse(try expectationSchema(plain).contains { $0.contains("invented_extra") })
    XCTAssertTrue(try expectationSchema(indexed).contains { $0.contains("invented_extra") })
    XCTAssertFalse(try expectationSchema(plain).contains { $0.contains("invented_extra") })
    XCTAssertEqual(try expectationSchema(indexed), try expectationSchema(indexed, full: true))
  }
  func testReusedSnapshotSeesCommitsFromOtherConnectionsBetweenTransactions() throws {
    let store = try open("invented.sqlite"), other = try open("invented.sqlite")
    try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
    // A first proof leaves its snapshot connection for reuse.
    _ = try store.appendSamples([TimeSample(ts: 100, bundleID: "invented", window: "Invented first")])
    _ = try other.appendSamples([TimeSample(ts: 200, bundleID: "invented", window: "Invented second")])
    // The proof seeds the updated row from its baseline. A stale baseline would not
    // contain it, and the live UPDATE would then be an unplanned write.
    try store.locked {
      try store.connection.transaction(collectionMaintenance: true) {
        try store.connection.collectionWrite("UPDATE samples SET window='' WHERE ts=?", [.integer(200)])
      }
    }
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM samples WHERE ts=200 AND window=''"), 1)
  }
}
