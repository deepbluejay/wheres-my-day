@testable import Core
import Foundation
@testable import Inbound
@testable import Storage
import XCTest

extension AgentLogTests {
  func testTenthAdoptedEvidenceKeepsLegacyRefusalsThroughFutureForget() throws {
    var cases: [(AgentLogTool, String, String, String, Bool)] = [
      (.codex, "a:b", "c", "d", false), (.codex, "a", "b:c", "d", false),
      (.codex, "a", "b", "c:d", false), (.codex, "legacy", "b", "d", false),
      (.codex, "a", "b", "d", false), (.codex, "a:b", "c", "d", true),
      (.codex, "{ \\\"password\\\" : \\\"invented\\\" }", "b", "d", true),
      (.codex, String(repeating: "x:", count: 4096), "b", "d", true),
      (.codex, String(repeating: "x", count: 1 << 20) + ":tail", "b", "d", false),
    ]
    for value in ["invented-id", "a:b", "legacy:b:d", "occurrence:b:d", "native:sha256:invented",
      "{ \"password\" : \"invented\" }", String(repeating: "x", count: 1 << 20) + ":tail"] {
      cases.append((.claude, value, "", "", false))
    }
    var runs = 0
    for (tool, thread, turn, item, header) in cases {
      for forget in [true, false] {
        try autoreleasepool {
          let base = root.appendingPathComponent("future-\(runs)")
          try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
          let database = base.appendingPathComponent("invented.sqlite")
          var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
          try storage.saveSettings(StorageSettings(), at: 0)
          let old = Redaction.applyKnownSecrets(tool == .claude ? "claude:" + thread : "codex:" + thread + ":" + turn + ":" + item).text
          try storage.connection.run("INSERT INTO evidence(ts,kind,source,source_id,document_key,project,text) VALUES(200,'prompt','invented-original',?,'','invented-project','Invented retained instruction')", [.key(old)])
          try storage.connection.run("PRAGMA user_version=9")
          func reopen() throws {
            storage = nil
            storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
          }
          try reopen()
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_legacy_evidence_keys WHERE digest=?", [.key(AgentLogLegacyRefusal.digest(old))]), 1)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence WHERE project='invented-project' AND text='Invented retained instruction'"), 1)
          func read(_ name: String, time: Int) throws -> String? {
            var records: [String] = []
            if tool == .claude {
              records.append(try json(["type": "user", "sessionId": "invented-session", "uuid": thread,
                "timestamp": stamp(time), "message": ["role": "user", "content": "Invented retained instruction"]]))
            } else {
              var payload: [String: Any] = ["thread_id": thread, "turn_id": turn, "type": "item_completed",
                "item": ["id": item, "type": "UserMessage", "content": [["type": "text", "text": "Invented retained instruction"]]]]
              if header {
                payload.removeValue(forKey: "thread_id")
                records.append(try json(["type": "session_meta", "timestamp": stamp(190), "payload": ["id": thread]]))
              }
              records.append(try json(["type": "event_msg", "timestamp": stamp(time), "payload": payload]))
            }
            let url = base.appendingPathComponent(name + ".jsonl")
            try Data((records.joined(separator: "\n") + "\n").utf8).write(to: url)
            let source = try XCTUnwrap(AgentLogFiles.listing([base.path]).files.first { $0.path == url.path })
            var position: LogPosition?
            var identity: String?
            repeat {
              let batch = try AgentLogFiles.read(source, tool: tool, position: position, at: 300)
              identity = batch.evidence.first?.sourceID ?? identity
              try storage.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
              position = batch.position
            } while (position?.offset ?? 0) < source.size
            return identity
          }
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_prompt_edges"), 0)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_evidence_origins"), 0)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_source_evidence"), 0)
          // Existing permitted native content deduplicates via the additive receipt,
          // including ambiguous/reserved tuples, before either forget or retention.
          _ = try read("invented-original", time: 202)
          try reopen()
          _ = try read("invented-copy", time: 202)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 1, "adopted duplicate \(runs)")
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_source_evidence"), 2)
          if forget {
            let preview = try storage.previewDeletion(in: TimeRange(200, 201))
            try storage.deleteRecords(in: preview.range, confirmation: preview.confirmation)
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM forgotten_sources WHERE source='invented-original' AND source_id=?", [.key(AgentLogLegacyRefusal.marker(AgentLogLegacyRefusal.digest(old)))]), 1)
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_legacy_refusals WHERE digest=?", [.key(AgentLogLegacyRefusal.digest(old))]), 1)
          } else {
            try storage.cleanRetention(at: 10_000_000)
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_legacy_refusals"), 0)
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM forgotten_sources"), 0)
          }
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_legacy_evidence_keys"), 0)
          try reopen()
          _ = try read("invented-later", time: 204)
          try reopen()
          _ = try read("invented-latest", time: 206)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), forget ? 0 : 1, "future forget \(runs)")
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE ts IN (204,206)"), forget ? 0 : 2)
          storage = nil
          runs += 1
        }
      }
    }
    print("Tenth adopted evidence matrix: \(runs) future-forget/retention runs; legacy receipts create no lineage, forget persists through restarts, retention readmits")
  }

  func testTenthLegacyEvidencePreviewAndPostWriteRefusalVerification() throws {
    let database = root.appendingPathComponent("invented.sqlite")
    try store.connection.run("INSERT INTO evidence(ts,kind,source,source_id,document_key,project,text) VALUES(200,'prompt','invented-source','codex:a:b:c:d','','','Invented instruction')")
    try store.connection.run("PRAGMA user_version=9")
    store = nil
    store = try ActivityStorage(url: database, appDataDirectory: root, databaseScope: .directory(root))
    let preview = try store.previewDeletion(in: TimeRange(200, 201))
    try store.connection.run("UPDATE agent_log_legacy_evidence_keys SET source_id='codex:invented:replacement:key'")
    XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_legacy_refusals"), 0)
    try store.connection.run("UPDATE agent_log_legacy_evidence_keys SET source_id='codex:a:b:c:d'")
    let fresh = try store.previewDeletion(in: TimeRange(200, 201))
    try store.connection.run("CREATE TRIGGER invented_undo_legacy_refusal AFTER DELETE ON evidence BEGIN DELETE FROM agent_log_legacy_refusals; END")
    XCTAssertThrowsError(try store.deleteRecords(in: fresh.range, confirmation: fresh.confirmation)) {
      XCTAssertEqual(($0 as? StorageError)?.description, "Legacy deletion source marker missing")
    }
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_legacy_evidence_keys"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_sources"), 0)
    try store.connection.run("DROP TRIGGER invented_undo_legacy_refusal")
    let final = try store.previewDeletion(in: TimeRange(200, 201))
    try store.deleteRecords(in: final.range, confirmation: final.confirmation)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_legacy_evidence_keys"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_legacy_refusals"), 1)
  }

  func testTenthAdoptedLegacyReceiptsNeverDeduplicateImplicitOrFingerprintCopies() throws {
    let body = "Invented independent instruction"
    for mode in ["implicit", "claude-fingerprint", "codex-fingerprint"] {
      let base = root.appendingPathComponent(mode)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      let database = base.appendingPathComponent("invented.sqlite")
      var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
      try storage.saveSettings(StorageSettings(), at: 0)
      let tool: AgentLogTool = mode == "codex-fingerprint" ? .codex : .claude
      let old = mode == "implicit" ? "claude:invented-command" : "\(tool.rawValue):legacy:202:\(AgentLogFiles.fingerprint(body))"
      try storage.connection.run("INSERT INTO evidence(ts,kind,source,source_id,document_key,project,text) VALUES(200,'prompt','invented-original',?,'','','Invented historical instruction')", [.key(old)])
      try storage.connection.run("PRAGMA user_version=9")
      storage = nil
      storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
      var records: [String] = []
      if mode == "implicit" {
        records.append(try json(["type": "queue-operation", "operation": "enqueue", "timestamp": stamp(190),
          "commandUuid": "invented-command", "content": body]))
        records.append(try json(["type": "user", "promptSource": "queued", "timestamp": stamp(202), "uuid": "invented-independent",
          "message": ["role": "user", "content": body]]))
      } else if tool == .claude {
        records.append(try json(["type": "user", "timestamp": stamp(202), "message": ["role": "user", "content": body]]))
      } else {
        records.append(try json(["type": "event_msg", "timestamp": stamp(202), "payload": ["type": "item_completed",
          "item": ["type": "UserMessage", "content": [["type": "text", "text": body]]]]]))
      }
      let url = base.appendingPathComponent("invented-independent.jsonl")
      try Data((records.joined(separator: "\n") + "\n").utf8).write(to: url)
      let source = try XCTUnwrap(AgentLogFiles.listing([base.path]).files.first { $0.path == url.path })
      let batch = try AgentLogFiles.read(source, tool: tool, position: nil, at: 300)
      try storage.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
      XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 2)
      XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_prompt_edges"), 0)
      XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_legacy_refusals"), 0)
      XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_evidence_origins"), 1)
      if mode == "implicit" {
        let preview = try storage.previewDeletion(in: TimeRange(200, 201))
        try storage.deleteRecords(in: preview.range, confirmation: preview.confirmation)
        storage = nil
        storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
        let later = base.appendingPathComponent("invented-later.jsonl")
        let lines = [try json(["type": "queue-operation", "operation": "enqueue", "timestamp": stamp(190),
            "commandUuid": "invented-command", "content": body]),
          try json(["type": "user", "promptSource": "queued", "timestamp": stamp(206), "uuid": "invented-later",
            "message": ["role": "user", "content": body]])]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: later)
        let file = try XCTUnwrap(AgentLogFiles.listing([base.path]).files.first { $0.path == later.path })
        let copy = try AgentLogFiles.read(file, tool: .claude, position: nil, at: 300)
        try storage.appendLogEvents(copy.events, evidence: copy.evidence, position: copy.position)
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 1,
          "the independent occurrence outside the forgotten range remains")
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE ts=206"), 0)
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_prompt_edges"), 0)
      }
      storage = nil
    }
  }
}
