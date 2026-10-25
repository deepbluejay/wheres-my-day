import Core
@testable import Storage
import Foundation
import XCTest

final class CostMeasurementTests: XCTestCase {
  func testInventedDayCost() throws {
    guard ProcessInfo.processInfo.environment["AP_STORAGE_MEASURE"] == "1" else { throw XCTSkip("Opt-in measurement, no performance threshold") }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("invented.sqlite"), store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let base = 1000000
    let samples = (0..<86400).map { TimeSample(ts: base + $0, bundleID: "invented.editor", app: "Invented editor", window: "Invented work", documentKey: "invented-document", keys: $0 % 5 == 0 ? 1 : 0) }
    var start = Date()
    try store.appendSamples(samples)
    let writeSeconds = Date().timeIntervalSince(start)
    start = Date()
    XCTAssertEqual(try store.samples(in: TimeRange(base, base + 86400)).count, 86400)
    let readSeconds = Date().timeIntervalSince(start)
    try store.connection.run("PRAGMA wal_checkpoint(TRUNCATE)")
    let skeletonBytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
    var rows: [EvidenceText] = []
    for i in 0..<1800 {
      let suffix = String(UnicodeScalar(65 + i % 26)!) + String(UnicodeScalar(65 + i / 26 % 26)!) + String(UnicodeScalar(65 + i / 676)!)
      let length = i < 1000 ? 156 : 155
      let text = "Invented screen line " + suffix + String(repeating: "a", count: length - 24)
      rows.append(EvidenceText(ts: base + i * 48, kind: .screen, source: "invented.editor", text: text))
    }
    XCTAssertEqual(rows.reduce(0) { $0 + $1.text.count }, 280000)
    start = Date(); try store.appendFixtureEvidence(rows)
    let evidenceSeconds = Date().timeIntervalSince(start)
    try store.connection.run("PRAGMA wal_checkpoint(TRUNCATE)")
    let evidenceBytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
    start = Date(); let keys = try store.recentScreenLineKeys(at: base + 86400)
    let keysSeconds = Date().timeIntervalSince(start)
    print("COST samples=86400 write_s=\(writeSeconds) read_s=\(readSeconds) skeleton_bytes=\(skeletonBytes) evidence=1800 characters=280000 evidence_write_s=\(evidenceSeconds) total_bytes=\(evidenceBytes) last_hour_keys=\(keys.count) last_hour_s=\(keysSeconds)")
  }
}
