import Core
import Foundation
import Query
import XCTest

/// The size bounds the recorded golden does not reach: an answer over 4 MiB is refused with its own code, an
/// answer over one line limit still leaves the helper as one reply, and so does one just under 4 MiB whose
/// escaped reply line is past four line limits. Invented intervals only.
extension QueryTests {
  /// One-minute intervals from `start`, each with its own invented description of `width` characters.
  private func largeQuery(intervals count: Int, width: Int, filler: (Int) -> String = { "invented \($0) " }) throws -> ActivityQueries {
    let begin = start + 86400
    try writer.appendIntervals((0..<count).map { index in
      NamedInterval(range: TimeRange(begin + index * 60, begin + index * 60 + 60), name: "Invented item \(index)",
        description: String(repeating: filler(index), count: width / filler(index).count + 1).prefix(width).description, kind: .work)
    })
    return ActivityQueries(storage: reader, calendar: calendar, now: { begin + 30 * 86400 })
  }
  private func recentWork(intervals count: Int) -> String {
    let begin = start + 86400
    return "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"recent_work\",\"arguments\":{\"from\":\(begin),\"to\":\(begin + count * 60)}}}"
  }
  private static let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#

  // Ideal: an answer that encodes past four line limits is refused as answer_too_large, not sent.
  func testAnswerOverFourLineLimitsIsRefusedWithItsOwnCode() throws {
    let count = 3000
    let large = try largeQuery(intervals: count, width: 1600)
    XCTAssertGreaterThan(try JSONEncoder().encode(large.recentWork(in: TimeRange(start + 86400, start + 86400 + count * 60))).count,
      4 * ActivityQueryServer.lineLimit, "the invented answer is past the bound")
    let server = ActivityQueryServer(queries: large, authorized: { true })
    XCTAssertNotNil(server.reply(to: Data(Self.initialize.utf8)))
    let reply = try XCTUnwrap(server.reply(to: Data(recentWork(intervals: count).utf8)))
    XCTAssertEqual(String(decoding: reply, as: UTF8.self),
      #"{"error":{"code":-32002,"message":"answer_too_large"},"id":2,"jsonrpc":"2.0"}"#)
  }

  // Ideal: an answer past one line limit (but within four) reaches the client whole, as one line.
  func testAnswerOverOneLineLimitIsServedAsOneLine() throws {
    try assertServedAsOneLine(intervals: 1000, width: 1600, filler: { "invented \($0) " }, pastLineLimits: 1, answerPast: 0)
  }

  // Ideal: an answer just under four line limits is not refused, and its reply line, which escaping makes longer
  // than four line limits, still reaches the client whole.
  func testAnswerJustUnderFourLineLimitsIsServedAsOneLine() throws {
    // A slash is escaped once in the answer and again in the reply line.
    try assertServedAsOneLine(intervals: 1300, width: 1600, filler: { _ in "a/b/" }, pastLineLimits: 4, answerPast: 3)
  }

  // Ideal: an answer just under four line limits made almost only of slashes, each escaped once in the answer and
  // again in the reply line, reaches the client whole: its reply line is past seven line limits, which the reply
  // bound of eight line limits allows.
  func testAnswerOfSlashesJustUnderFourLineLimitsIsServedAsOneLine() throws {
    try assertServedAsOneLine(intervals: 1300, width: 1600, filler: { _ in "/" }, pastLineLimits: 7, answerPast: 3, fillToBound: true)
  }

  private func assertServedAsOneLine(intervals count: Int, width: Int, filler: (Int) -> String, pastLineLimits: Int,
    answerPast: Int, fillToBound: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
    let written = count
    let large = try largeQuery(intervals: written, width: width, filler: filler)
    func size(_ intervals: Int) throws -> Int {
      try JSONEncoder().encode(large.recentWork(in: TimeRange(start + 86400, start + 86400 + intervals * 60))).count
    }
    var count = count
    if fillToBound {
      // The most intervals whose answer is within four line limits: one more would pass them.
      let base = try size(1), row = try size(2) - base
      count = min(written, (4 * ActivityQueryServer.lineLimit - base) / row + 1)
      while try size(count) > 4 * ActivityQueryServer.lineLimit { count -= 1 }
      XCTAssertLessThan(count, written, "the invented intervals reach past the bound", file: file, line: line)
      XCTAssertGreaterThan(try size(count + 1), 4 * ActivityQueryServer.lineLimit, file: file, line: line)
    }
    let size = try size(count)
    XCTAssertLessThanOrEqual(size, 4 * ActivityQueryServer.lineLimit, "the invented answer is within the bound", file: file, line: line)
    XCTAssertGreaterThan(size, answerPast * ActivityQueryServer.lineLimit, "the invented answer is past \(answerPast) line limits",
      file: file, line: line)
    let folder = root.appendingPathComponent("serve")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let input = folder.appendingPathComponent("input"), output = folder.appendingPathComponent("output")
    try Data((Self.initialize + "\n" + recentWork(intervals: count) + "\n").utf8).write(to: input)
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let reading = try FileHandle(forReadingFrom: input), writing = try FileHandle(forWritingTo: output)
    ActivityQueryServer(queries: large, authorized: { true }).serve(input: reading, output: writing)
    try reading.close(); try writing.close()
    let lines = try Data(contentsOf: output).split(separator: 10, omittingEmptySubsequences: false)
    XCTAssertEqual(lines.count, 3, "two replies, each ended by a newline", file: file, line: line)
    let answer = try XCTUnwrap(lines.dropFirst().first, file: file, line: line)
    XCTAssertGreaterThan(answer.count, pastLineLimits * ActivityQueryServer.lineLimit, "the reply is past \(pastLineLimits) line limits",
      file: file, line: line)
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(answer)) as? [String: Any])
    let result = try XCTUnwrap(object["result"] as? [String: Any])
    XCTAssertEqual(result["isError"] as? Bool, false, file: file, line: line)
    let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
    let rows = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["rows"] as? [Any])
    XCTAssertEqual(rows.count, count, file: file, line: line)
  }
}
