@testable import Core
import Foundation
@testable import Inbound
@testable import Storage
import XCTest

extension AgentLogTests {
  func testTenthMainJoinedTombstoneAdoptionMatrix() throws {
    let values = ["ordinary", "a:b", "legacy:b:d", "occurrence:b:d", "native:sha256:invented", "password",
      "activityprobe:long-identity:sha256:invented", String(repeating: "x:", count: 4096),
      String(repeating: "x", count: 1 << 20) + ":tail", "password:" + String(repeating: "x", count: 8192),
      "\"password\"  ", "{ \"password\" : \"invented\" }", "{ \"ordinary\" : \"invented\" }",
      "{ \\\"password\\\" : \\\"invented\\\" }", "password:\\u0069nvented", " \t[\"password\"] "]
    var cases: [(AgentLogTool, String, String, String, String)] = []
    for value in values {
      for field in ["uuid", "commandUuid", "source_uuid", "attachment.source_uuid"] {
        cases.append((.claude, field, value, "", ""))
      }
      for field in ["thread", "turn", "item", "header.id", "header.session_id"] {
        cases.append((.codex, field, field == "turn" || field == "item" ? "a" : value,
          field == "turn" ? value : "b", field == "item" ? value : "d"))
      }
    }
    // These exact five tuples exposed the main-format adoption regression.
    for tuple in [("a:b", "c", "d"), ("a", "b:c", "d"), ("a", "b", "c:d"),
      ("legacy", "b", "d"), ("a", "b", "d")] {
      cases.append((.codex, "tuple", tuple.0, tuple.1, tuple.2))
    }
    var runs = 0
    for (index, entry) in cases.enumerated() {
      for tombstone in [true, false] {
        try autoreleasepool {
          let (tool, field, first, turn, item) = entry
          let base = root.appendingPathComponent("adoption-\(index)-\(tombstone)")
          try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
          let database = base.appendingPathComponent("invented.sqlite")
          var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
          try storage.saveSettings(StorageSettings(), at: 0)
          let old = Redaction.applyKnownSecrets(tool == .claude ? "claude:" + first : "codex:" + first + ":" + turn + ":" + item).text
          if tombstone {
            try storage.connection.run("INSERT INTO forgotten_sources VALUES('invented-old-source',?)", [.key(old)])
          }
          try storage.connection.run("INSERT INTO forgotten_ranges VALUES(100,101)")
          // Adoption must initialize the bridge from the pre-channel schema, not
          // depend on relations that this test's initial fresh database provided.
          try storage.connection.run("DROP TABLE agent_log_legacy_refusals")
          try storage.connection.run("PRAGMA user_version=9")
          func reopen() throws {
            storage = nil
            storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
          }
          try reopen()
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM forgotten_sources WHERE source_id=?", [.key(old)]), tombstone ? 1 : 0,
            "original tombstone \(index)")
          for restart in 0..<2 {
            var records: [String] = []
            if tool == .claude {
              var line: [String: Any] = ["type": "user", "sessionId": "invented-session", "uuid": "invented-item",
                "timestamp": stamp(202), "message": ["role": "user", "content": "Invented tenth instruction"]]
              if field == "attachment.source_uuid" {
                line["type"] = "attachment"
                line["attachment"] = ["type": "queued_command", "humanTurn": true, "source_uuid": first, "prompt": "Invented tenth instruction"]
              } else { line[field] = first }
              records.append(try json(line))
            } else {
              var payload: [String: Any] = ["thread_id": first, "turn_id": turn, "type": "item_completed",
                "item": ["id": item, "type": "UserMessage", "content": [["type": "text", "text": "Invented tenth instruction"]]]]
              if field.hasPrefix("header.") {
                payload.removeValue(forKey: "thread_id")
                records.append(try json(["type": "session_meta", "timestamp": stamp(199), "payload": [String(field.dropFirst(7)): first]]))
              }
              records.append(try json(["type": "event_msg", "timestamp": stamp(202), "payload": payload]))
            }
            let url = base.appendingPathComponent("invented-copy-\(restart).jsonl")
            try Data((records.joined(separator: "\n") + "\n").utf8).write(to: url)
            let source = try XCTUnwrap(AgentLogFiles.listing([base.path]).files.first { $0.path == url.path })
            var position: LogPosition?
            repeat {
              let batch = try AgentLogFiles.read(source, tool: tool, position: position, at: 300,
                ownSources: AgentLogFiles.ownSources(appDataDirectory: base))
              XCTAssertGreaterThan(batch.position.offset, position?.offset ?? -1)
              try storage.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
              // Every actual reader boundary survives a storage/checkpoint restart,
              // including the 1 MiB header drained through metadata-only batches.
              position = try storage.logPosition(path: url.path)
              try reopen()
            } while (position?.offset ?? 0) < source.size
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), tombstone ? 0 : 1,
              "evidence \(index) \(tool) \(field) restart=\(restart)")
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE ts=202"), tombstone ? 0 : restart + 1,
              "events \(index) \(tool) \(field) restart=\(restart)")
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM forgotten_sources WHERE source='invented-old-source' AND source_id=?", [.key(old)]), tombstone ? 1 : 0)
          }
          storage = nil
          runs += 1
        }
      }
    }
    print("Tenth adoption matrix: \(cases.count) identities, \(runs) tombstone/control runs, two copies and checkpoint/storage restarts; zero resurrection")
  }

  func testTenthLegacyFallbackAndRangeRefusalsSurviveAdoption() throws {
    for tool in AgentLogTool.allCases {
      for seed in ["fallback", "range", "none"] {
        let base = root.appendingPathComponent("fallback-\(tool)-\(seed)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let database = base.appendingPathComponent("invented.sqlite")
        var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
        try storage.saveSettings(StorageSettings(), at: 0)
        let old = "\(tool.rawValue):legacy:202:\(AgentLogFiles.fingerprint("Invented fallback instruction"))"
        if seed == "fallback" {
          try storage.connection.run("INSERT INTO forgotten_sources VALUES('invented-source',?)", [.key(old)])
        }
        if seed == "range" { try storage.connection.run("INSERT INTO forgotten_ranges VALUES(202,203)") }
        try storage.connection.run("PRAGMA user_version=9")
        storage = nil
        for restart in 0..<2 {
          storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
          let line: [String: Any] = tool == .claude
            ? ["type": "user", "timestamp": stamp(202), "message": ["role": "user", "content": "Invented fallback instruction"]]
            : ["type": "event_msg", "timestamp": stamp(202), "payload": ["type": "item_completed",
                "item": ["type": "UserMessage", "content": [["type": "text", "text": "Invented fallback instruction"]]]]]
          let url = base.appendingPathComponent("invented-source-\(restart).jsonl")
          try Data((json(line) + "\n").utf8).write(to: url)
          let source = try XCTUnwrap(AgentLogFiles.listing([base.path]).files.first { $0.path == url.path })
          let batch = try AgentLogFiles.read(source, tool: tool, position: nil, at: 300)
          try storage.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), seed == "none" ? restart + 1 : 0)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events"), seed == "none" ? restart + 1 : 0)
          storage = nil
        }
      }
    }
  }

  func testTenthMainCodexFilenameAndTimestampDefaults() throws {
    for name in ["invented-source", "a:b", "legacy", "occurrence"] {
      for tombstone in [true, false] {
        let base = root.appendingPathComponent("defaults-\(name)-\(tombstone)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let database = base.appendingPathComponent("invented.sqlite")
        var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
        try storage.saveSettings(StorageSettings(), at: 0)
        let old = "codex:\(name):202:invented-item"
        if tombstone { try storage.connection.run("INSERT INTO forgotten_sources VALUES('invented-old-source',?)", [.key(old)]) }
        try storage.connection.run("PRAGMA user_version=9")
        storage = nil
        for restart in 0..<2 {
          storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
          let folder = base.appendingPathComponent("copy-\(restart)")
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          let url = folder.appendingPathComponent(name + ".jsonl")
          let line = try json(["type": "event_msg", "timestamp": stamp(202), "payload": ["type": "item_completed",
            "item": ["id": "invented-item", "type": "UserMessage", "content": [["type": "text", "text": "Invented default instruction"]]]]])
          try Data((line + "\n").utf8).write(to: url)
          let source = try XCTUnwrap(AgentLogFiles.listing([folder.path]).files.first)
          let batch = try AgentLogFiles.read(source, tool: .codex, position: nil, at: 300)
          try storage.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), tombstone ? 0 : 1)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events"), tombstone ? 0 : restart + 1)
          storage = nil
        }
      }
    }
  }

  func testTenthEscapedStringsNeverRepairInvalidUTF8() throws {
    let reported = [
      "eyJwYXlsb2FkIjp7ImN3ZCI6WzEsMiwzXSwiaWQiOnRydWUsIml0ZW0iOnsib3JpZ2luYXRvciI6MH0sIm9yaWdpbmF0b3IiOlsxLDIsM10sInRocmVhZF9pZCI6bnVsbH0sInBheWxvYWQuaWQiOjAsInNlc3Npb25JZCI6WzEsMiwzXSwidHlwZSI6ImV2ZW50X21zZyIsInVua25vd24iOiJcXHWpMDczIn0=",
      "eyJwYXlsb2FkIjp7ImN3ZCI6WzEsMiwzXSwiaWQiOlsxLDIsM10sIml0ZW0iOnsib3JpZ2luYXRvciI6IlxcdTAwqTczIn0sIm9yaWdpbmF0b3IiOiJvcmRpbmFyeSIsInRocmVhZF9pZCI6MH0sInBheWxvYWQuaWQiOm51bGwsInNlc3Npb25JZCI6dHJ1ZSwidHlwZSI6ImV2ZW50X21zZyIsInVua25vd24iOjEuMjV9"]
    var cases = reported.compactMap { Data(base64Encoded: $0) }
    for escape in ["\\\\u", "\\n", "\\u00", "prefix\\t"] {
      for byte: UInt8 in [0x80, 0xa9, 0xc0, 0xff] {
        var bytes = Data(("{\"x\":\"" + escape).utf8)
        bytes.append(byte); bytes.append(Data("073\"}".utf8))
        cases.append(bytes)
      }
    }
    for bytes in cases {
      var metadata = AgentLogMetadata()
      for byte in bytes { metadata.consume(byte) }
      XCTAssertFalse(metadata.complete)
      XCTAssertNil(AgentLogJSON.object(bytes))
    }
    for text in [#"{"x":"\\u©073"}"#, #"{"x":"\n©073"}"#, #"{"x":"\u0073©"}"#] {
      XCTAssertNotNil(AgentLogJSON.object(Data(text.utf8)))
    }
  }

  func testTenthImplicitQueuePairingOnlyConsultsLegacyRefusals() throws {
    var cases = 0
    let body = "Invented implicit queue instruction"
    for mode in ["enqueue", "attachment", "absorbed", "removed", "fallback", "checkpoint-pending", "checkpoint-delivered",
      "checkpoint-delivered-nil", "checkpoint-old-delivered"] {
      for value in ["invented-command", "a:b", "legacy:b:d", String(repeating: "x", count: 8192)] {
        for tombstone in [true, false] {
          let base = root.appendingPathComponent("queue-\(cases)")
          try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
          let database = base.appendingPathComponent("invented.sqlite")
          var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
          try storage.saveSettings(StorageSettings(), at: 0)
          let old = mode == "fallback" || mode == "checkpoint-delivered-nil"
            ? "claude:legacy:100:\(AgentLogFiles.fingerprint(body))" : "claude:" + value
          if tombstone { try storage.connection.run("INSERT INTO forgotten_sources VALUES('invented-old-source',?)", [.key(old)]) }
          try storage.connection.run("INSERT INTO forgotten_ranges VALUES(100,101)")
          try storage.connection.run("PRAGMA user_version=9")
          storage = nil
          for restart in 0..<2 {
            storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
            var records: [String] = []
            if mode == "attachment" {
              records.append(try json(["type": "attachment", "timestamp": stamp(100),
                "attachment": ["type": "queued_command", "humanTurn": true, "source_uuid": value, "prompt": body]]))
            } else if !mode.hasPrefix("checkpoint-") {
              var enqueue: [String: Any] = ["type": "queue-operation", "operation": "enqueue", "timestamp": stamp(100),
                "commandUuid": mode == "absorbed" ? "invented-predecessor" : value, "content": body]
              if mode == "fallback" { enqueue.removeValue(forKey: "commandUuid") }
              records.append(try json(enqueue))
              if mode == "absorbed" || mode == "removed" {
                records.append(try json(["type": "queue-operation", "operation": "remove", "timestamp": stamp(101),
                  "reason": mode == "absorbed" ? "absorbed_mid_turn" : "cancelled", "commandUuid": value, "content": body]))
              }
            }
            var delivery: [String: Any] = ["type": "user", "timestamp": stamp(202 + restart), "uuid": "invented-copy-\(restart)",
              "promptSource": "queued", "message": ["role": "user", "content": body]]
            if mode == "fallback" { delivery.removeValue(forKey: "uuid") }
            records.append(try json(delivery))
            let url = base.appendingPathComponent("invented-copy-\(restart).jsonl")
            try Data((records.joined(separator: "\n") + "\n").utf8).write(to: url)
            let source = try XCTUnwrap(AgentLogFiles.listing([base.path]).files.first { $0.path == url.path })
            var position: LogPosition?
            if mode.hasPrefix("checkpoint-") {
              let delivered = mode != "checkpoint-pending"
              var receipt: [String: Any] = ["hash": AgentLogFiles.fingerprint(body), "id": delivered ? old : value,
                "ts": 100, "delivered": delivered]
              if mode == "checkpoint-delivered-nil" { receipt.removeValue(forKey: "id") }
              var checkpoint: [String: Any] = ["metadataRead": true, "project": "", "queued": [receipt]]
              if mode == "checkpoint-old-delivered" {
                receipt["id"] = value; receipt["sourceID"] = old
                checkpoint.removeValue(forKey: "metadataRead"); checkpoint["queued"] = [receipt]
              }
              let state = try json(checkpoint)
              position = LogPosition(path: url.path, device: source.device, inode: source.inode, offset: 0, state: state, seenAt: 300)
              // A main checkpoint is adopted through the real storage path before reading.
              try storage.saveLogPosition(try XCTUnwrap(position))
              storage = nil
              storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
              position = try storage.logPosition(path: url.path)
            }
            let batch = try AgentLogFiles.read(source, tool: .claude, position: position, at: 300)
            if mode != "fallback" { XCTAssertEqual(batch.evidence.last?.sourceID, "claude:invented-copy-\(restart)") }
            XCTAssertFalse(batch.events.last?.identities.contains(AgentLogIdentity.claude(value)) ?? true)
            let state = try AgentLogState.decode(batch.position.state)
            XCTAssertEqual(state.queued.count, 0)
            XCTAssertLessThanOrEqual(state.legacyRefusalQueue.count, AgentLogState.queueLimit)
            XCTAssertFalse(batch.position.state.contains(value.count > 100 ? String(value.prefix(100)) : "\"" + value + "\""))
            try storage.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
            let refused = tombstone && mode != "removed"
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), refused ? 0 : restart + 1,
              "\(mode) \(value.utf8.count) tombstone=\(tombstone)")
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE role='user'"), refused ? 0 : restart + 1)
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_prompt_edges"), 0,
              "implicit pairing must never create identity edges")
            storage = nil
          }
          cases += 1
        }
      }
    }
    print("Tenth implicit queue matrix: \(cases) runs, pending/delivered legacy checkpoints, no implicit identity edges, independent controls collected")
  }
}
