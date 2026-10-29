import Core
import Foundation
import Query
import Shell
import Storage
import XCTest

extension QueryTests {
  func testAXOnlySentinelIsAbsentFromSummaryInputAndAllFiveQueryMCPReplies() throws {
    let axOnly = "InventedAXOnlySentinel", ordinary = "InventedOrdinaryOCRSentinel"
    let run = try writer.enableAXProbe(at: start)
    let request = AXProbeRequest(run: run, time: start + 60, window: WindowIdentity(processID: 10, windowID: 20),
      bundleID: "invented.editor", isBrowser: false)
    var ax = AXProbeResult(status: .completed); ax.text = axOnly; ax.start = 100; ax.end = 100.2
    ax.nodes = [AXProbeNode(nodeID: 1, role: "AXWebArea", hiddenBranch: true,
      attributes: [AXProbeText(attribute: "AXValue", text: axOnly)])]
    let pair = AXProbePair(request: request, ax: ax, ocrStatus: "completed", ocr: ordinary,
      imageRequest: 100, imageReturn: 100.1, ocrCompletion: 101)
    let evidence = try writer.appendScreenCapture(text: ordinary, at: start + 60, source: "invented.editor", knownKeys: [])
    XCTAssertTrue(try writer.appendAXProbe(pair, evidenceID: evidence.evidenceID, at: start + 60))
    let range = TimeRange(start, start + 600)
    let format = SummaryFormat(timeZone: TimeZone(secondsFromGMT: 0)!)
    let table = format.table(range: range, samples: try reader.samples(in: range), evidence: try reader.evidence(in: range))
    let prompt = format.prompt(range: range, table: table, previous: try reader.intervals(in: range), names: [], locale: "en")
    XCTAssertTrue(table.contains(ordinary)); XCTAssertTrue(prompt.contains(ordinary))
    XCTAssertFalse(table.contains(axOnly)); XCTAssertFalse(prompt.contains(axOnly))
    let answers = [try query.recentWork(in: range), try query.whatWasIDoing(at: start + 60, minutes: 1),
      try query.search("review plan", in: range), try query.timeTotals(in: range), try query.daySummary(containing: start)]
    for answer in answers {
      let encoded = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
      XCTAssertFalse(encoded.contains(axOnly))
    }
    let server = ActivityQueryServer(queries: query, authorized: { true })
    func reply(_ method: String, _ params: [String: Any]) throws -> String {
      let bytes = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
      return String(decoding: try XCTUnwrap(server.reply(to: bytes)), as: UTF8.self)
    }
    _ = try reply("initialize", ["protocolVersion": "2025-11-25"])
    let tools: [(String, [String: Any])] = [
      ("recent_work", ["from": range.start, "to": range.end]),
      ("what_was_i_doing", ["at": start + 60, "minutes": 1]),
      ("search_activity", ["from": range.start, "to": range.end, "query": "review plan"]),
      ("time_breakdown", ["from": range.start, "to": range.end]), ("day_summary", ["at": start])]
    var output = ""
    for (name, arguments) in tools {
      let response = try reply("tools/call", ["name": name, "arguments": arguments])
      XCTAssertFalse(response.contains(axOnly)); XCTAssertTrue(response.contains("\"isError\":false"), name)
      output += response
    }
    XCTAssertTrue(output.contains("Invented plan"))
  }
}
