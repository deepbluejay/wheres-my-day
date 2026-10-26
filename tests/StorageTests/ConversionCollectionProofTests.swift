import Core
import Foundation
import XCTest
@testable import Storage

extension ConversionTests {
  func testConversionCollectionWritesUseEntryBaselineWithControlsAndRestart() throws {
    for table in ["samples", "evidence"] { for fault in [false, true] {
      let child = ConversionTests()
      try child.setUpWithError()
      defer { try! child.tearDownWithError() }
      let source = try child.oldDatabase(), destination = child.folder.appendingPathComponent("invented-new.sqlite")
      var store: ActivityStorage? = try ActivityStorage(url: destination, appDataDirectory: child.folder, databaseScope: .directory(child.folder))
      if fault {
        let bytes = CompactInput.encode([InputObservation(kind: .move, timestamp: 99.5)]).map { String(format: "%02x", $0) }.joined()
        try store!.connection.run("CREATE TRIGGER invented_fault AFTER INSERT ON \(table) BEGIN INSERT OR IGNORE INTO input_batches(observation_id,ts,events) VALUES('invented-extra',99,X'\(bytes)'); END")
        XCTAssertThrowsError(try store!.convertOldDatabase(at: source, batchSize: 8))
        XCTAssertEqual(try store!.connection.integer("SELECT count(*) FROM \(table)"), 0)
        XCTAssertEqual(try store!.connection.integer("SELECT count(*) FROM input_batches"), 0)
        XCTAssertEqual(try store!.connection.integer("SELECT last_row FROM conversion_progress WHERE layer=?", [.key(table)]), 0)
        try store!.connection.run("DROP TRIGGER invented_fault")
        store = nil
        store = try ActivityStorage(url: destination, appDataDirectory: child.folder, databaseScope: .directory(child.folder))
      }
      XCTAssertTrue(try store!.convertOldDatabase(at: source, batchSize: 8).finished)
      XCTAssertEqual(try store!.samples(in: child.all).count, 8)
      XCTAssertEqual(try store!.evidence(in: child.all).count, 8)
      XCTAssertEqual(try store!.connection.integer("SELECT count(*) FROM input_batches"), 0)
      XCTAssertTrue(try store!.convertOldDatabase(at: source, batchSize: 8).finished)
      store = nil
    } }
  }
}
