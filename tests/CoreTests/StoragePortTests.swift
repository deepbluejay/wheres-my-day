import Core
import Foundation
import XCTest

final class StoragePortTests: XCTestCase {
  final class MemorySamples: SampleWriter, SampleReader {
    var rows: [TimeSample] = []
    @discardableResult func appendSamples(_ samples: [TimeSample]) throws -> AppendResult {
      rows.append(contentsOf: samples)
      return AppendResult(stored: samples.count)
    }
    func samples(in range: TimeRange) throws -> [TimeSample] { rows.filter { $0.ts >= range.start && $0.ts < range.end } }
  }
  func testConsumerUsesSmallPortsWithoutSQLite() throws {
    let fake = MemorySamples()
    let writer: SampleWriter = fake, reader: SampleReader = fake
    try writer.appendSamples([TimeSample(ts: 1, synthetic: 4), TimeSample(ts: 2, keys: 1)])
    XCTAssertFalse(try reader.samples(in: TimeRange(1, 2))[0].hasInput)
    XCTAssertTrue(try reader.samples(in: TimeRange(2, 3))[0].hasInput)
  }
}
