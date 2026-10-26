@testable import Core
@testable import Storage
@testable import Inbound
import Foundation
import SQLite3
import XCTest

private final class LogVMWork { var ticks = 0 }

extension AgentLogTests {
  func testGeneratedWriterWorkIsIndependentOfUnrelatedPromptsAtOwnEOF() throws {
    var work: [Int] = []
    var ordinary: [[Int]] = []
    for count in [10_000, 100_000] {
      let base = root.appendingPathComponent("invented-population-\(count)")
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      let storage = try ActivityStorage(url: base.appendingPathComponent("invented.sqlite"),
        appDataDirectory: base, databaseScope: .directory(base))
      try storage.saveSettings(StorageSettings(), at: 0)
      try storage.connection.run("""
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<?)
        INSERT INTO evidence(ts,kind,source,source_id,document_key,project,text)
        SELECT 100,'prompt','invented','claude:unrelated-'||x,'','','Invented' FROM n
        """, [.integer(count)])
      var state = AgentLogState(); state.tool = "claude"; state.ownWorkingFolder = true
      let position = LogPosition(path: base.appendingPathComponent("invented.jsonl").path,
        device: 71, inode: 83, offset: 50, state: try state.encoded(), seenAt: 200)
      try storage.appendLogEvents([], evidence: [], position: position)
      let counter = LogVMWork()
      sqlite3_progress_handler(storage.connection.handle, 1, { context in
        Unmanaged<LogVMWork>.fromOpaque(context!).takeUnretainedValue().ticks += 1
        return 0
      }, Unmanaged.passUnretained(counter).toOpaque())
      defer { sqlite3_progress_handler(storage.connection.handle, 0, nil, nil) }
      for _ in 0..<3 { try storage.appendLogEvents([], evidence: [], position: position) }
      sqlite3_progress_handler(storage.connection.handle, 0, nil, nil)
      work.append(counter.ticks)
      XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), count)
      print("Generated own EOF unrelated=\(count) vmSteps=\(counter.ticks)")
      var batchWork: [Int] = []
      for (index, seed) in logPropertySeeds.enumerated() {
        var random = LogTraceRandom(state: seed)
        let role = ["user", "assistant", "tool", "system"][random.next(4)]
        let text = try json(["type": role, "uuid": "invented-work-\(index)", "sessionId": "invented-foreign",
          "timestamp": stamp(100), "message": ["content": "Invented bounded writer work"]])
        var state = AgentLogState(); state.tool = "claude"
        let event = try XCTUnwrap(AgentLogEventParser.parse(Data(text.utf8), byteCount: text.utf8.count, offset: 0,
          observedAt: 200, tool: .claude, file: "/invented/work.jsonl", state: &state, logsRelativePath: nil,
          fingerprint: AgentLogFiles.fingerprint))
        let cursor = LogPosition(path: base.appendingPathComponent("invented-foreign-\(index).jsonl").path,
          device: 71, inode: 100 + index, offset: 1000, state: try state.encoded(), seenAt: 200)
        let measured = LogVMWork()
        sqlite3_progress_handler(storage.connection.handle, 1, { context in
          Unmanaged<LogVMWork>.fromOpaque(context!).takeUnretainedValue().ticks += 1
          return 0
        }, Unmanaged.passUnretained(measured).toOpaque())
        try storage.appendLogEvents([event], evidence: event.prompt.map { [$0] } ?? [], position: cursor)
        sqlite3_progress_handler(storage.connection.handle, 0, nil, nil)
        batchWork.append(measured.ticks)
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE inode=?", [.integer(100 + index)]), 1)
      }
      ordinary.append(batchWork)
      print("Generated ordinary writer unrelated=\(count) vmSteps=\(batchWork)")
    }
    XCTAssertLessThanOrEqual(work[1], work[0] + 30, "Unchanged own EOF must use constant VM work")
    for index in logPropertySeeds.indices {
      XCTAssertLessThanOrEqual(ordinary[1][index], ordinary[0][index] + 50, "Ordinary writer work grew with unrelated rows")
    }
  }

  func testLegacyOccurrenceCleanupUsesFullIndexedByteExactDeletePlan() throws {
    let query = ActivityStorage.legacyOccurrenceCleanupSQL
    let position = LogPosition(path: "invented", device: 71, inode: 83, offset: 0, state: "{}", seenAt: 200)
    let values = ActivityStorage.legacyOccurrenceCleanupValues(position, tool: .claude)
    var plan = [String]()
    try store.connection.namedRows("EXPLAIN QUERY PLAN " + query, values) {
      plan.append(try $0.text("detail"))
    }
    XCTAssertTrue(plan.contains { $0.contains("SEARCH evidence USING") && $0.contains("evidence_prompt_id (source_id>? AND source_id<?)") }, plan.joined(separator: "\n"))
    XCTAssertTrue(plan.contains { $0.contains("agent_log_source_evidence_id") }, plan.joined(separator: "\n"))
    for id in ["claude:occurrence:71:83:0", "Claude:occurrence:71:83:0", "claude:occurrence:71:830:0", "claude:occurrence:71:83;0"] {
      try store.connection.run("INSERT INTO evidence(ts,kind,source,source_id,document_key,project,text) VALUES(100,'prompt','invented',?,'','','Invented')", [.key(id)])
    }
    try store.connection.run(query, values)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence"), 3)
    XCTAssertFalse(plan.contains { $0.contains("SCAN evidence") || $0.contains("evidence_time_kind") }, plan.joined(separator: "\n"))
  }
}
