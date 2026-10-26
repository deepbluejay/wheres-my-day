@testable import Core
import Foundation
@testable import Inbound
@testable import Storage
import XCTest

extension AgentLogTests {
  func testNinthNativeIdentityCopyForgetRestartMatrix() throws {
    let sizes = [100, 4079, 4080, 4090, 4095, 4096, 4097, 4200, 8192, 1 << 20]
    var cases = 0
    for tool in AgentLogTool.allCases {
      let fields = tool == .claude ? ["uuid", "commandUuid", "source_uuid", "attachment.source_uuid", "sessionId"]
        : ["thread_id", "turn_id", "item.id", "header.id", "header.session_id"]
      for field in fields {
        for size in sizes {
          try autoreleasepool {
            let base = root.appendingPathComponent("matrix-\(tool)-\(field)-\(size)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let database = base.appendingPathComponent("invented.sqlite")
            var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
            try storage.saveSettings(StorageSettings(), at: 0)
            let value = String(repeating: "x", count: size)
            func reopen() throws {
              storage = nil
              storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
            }
            func read(_ name: String, _ time: Int) throws -> AgentLogBatch {
              var records: [String] = []
              if tool == .claude {
                var line: [String: Any] = ["type": "user", "sessionId": "invented-session", "uuid": "invented-item",
                  "timestamp": stamp(time), "message": ["role": "user", "content": "Invented ninth instruction"]]
                if field == "attachment.source_uuid" {
                  line["type"] = "attachment"
                  line["attachment"] = ["type": "queued_command", "humanTurn": true, "source_uuid": value, "prompt": "Invented ninth instruction"]
                } else { line[field] = value }
                records = [try json(line)]
              } else {
                var payload: [String: Any] = ["thread_id": "invented-thread", "turn_id": "invented-turn", "type": "item_completed",
                  "item": ["id": "invented-item", "type": "UserMessage", "content": [["type": "text", "text": "Invented ninth instruction"]]]]
                if field.hasPrefix("header.") {
                  payload.removeValue(forKey: "thread_id")
                  records.append(try json(["type": "session_meta", "timestamp": stamp(time), "payload": [String(field.dropFirst(7)): value]]))
                } else if field == "item.id" {
                  payload["item"] = ["id": value, "type": "UserMessage", "content": [["type": "text", "text": "Invented ninth instruction"]]]
                } else { payload[field] = value }
                records.append(try json(["type": "event_msg", "timestamp": stamp(time), "payload": payload]))
              }
              let url = base.appendingPathComponent(name + ".jsonl")
              try Data((records.joined(separator: "\n") + "\n").utf8).write(to: url)
              let source = try XCTUnwrap(AgentLogFiles.listing([base.path]).files.first { $0.path == url.path })
              var result = try AgentLogFiles.read(source, tool: tool, position: nil, at: 300,
                ownSources: AgentLogFiles.ownSources(appDataDirectory: base))
              while result.position.offset < source.size {
                let next = try AgentLogFiles.read(source, tool: tool, position: result.position, at: 300,
                  ownSources: AgentLogFiles.ownSources(appDataDirectory: base))
                XCTAssertGreaterThan(next.position.offset, result.position.offset)
                result.events += next.events; result.evidence += next.evidence
                result.position = next.position
              }
              return result
            }
            func commit(_ batch: AgentLogBatch) throws {
              try storage.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
            }
            let first = try read("invented-first", 200)
            let native = try XCTUnwrap(first.evidence.first?.sourceID, "\(tool) \(field) \(size)")
            XCTAssertTrue(AgentLogEventParser.isNativePromptIdentity(native), "\(tool) \(field) \(size)")
            XCTAssertEqual(AgentLogEventParser.safeIdentity(native), native)
            XCTAssertTrue(first.events.contains { $0.canonicalIdentity?.storedKey == native })
            try commit(first)
            try reopen()
            let copy = try read("invented-copy", 200)
            XCTAssertEqual(copy.evidence.first?.sourceID, native)
            try commit(copy)
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 1, "duplicate \(tool) \(field) \(size)")
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_evidence_origins"), 1)
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_source_evidence"), 2)
            let preview = try storage.previewDeletion(in: TimeRange(200, 201))
            try storage.deleteRecords(in: preview.range, confirmation: preview.confirmation)
            try reopen()
            try commit(read("invented-later", 202))
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 0, "resurrected \(tool) \(field) \(size)")
            // A session header has no instruction identity and is independently collected.
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE role='user'"), 0)
            XCTAssertGreaterThan(try storage.connection.integer("SELECT count(*) FROM forgotten_sources WHERE source_id=?", [.key(native)]), 0)
            storage = nil
            cases += 1
          }
        }
      }
    }
    print("Ninth native matrix: \(cases) cases; duplicate=1, resurrectedEvidence=0, restart before copy and after forget")
  }

  func testNinthCodexLiteralTupleCannotImpersonateDigestOrOccurrenceDomains() throws {
    let raw = String(repeating: "x", count: 8192)
    let digestKey = AgentLogEventParser.codexIdentity(thread: AgentLogEventParser.rawIdentity(raw), turn: "invented-turn", item: "invented-item")
    XCTAssertTrue(digestKey.hasPrefix("codex:native:sha256:"))
    let digest = String(digestKey.dropFirst("codex:native:sha256:".count))
    let literalKey = AgentLogEventParser.codexIdentity(thread: "native", turn: "sha256", item: digest)
    XCTAssertNotEqual(literalKey, digestKey)
    for thread in ["legacy", "occurrence"] {
      XCTAssertTrue(AgentLogEventParser.isNativePromptIdentity(
        AgentLogEventParser.codexIdentity(thread: thread, turn: "invented-turn", item: "invented-item")))
    }
    func read(_ name: String, thread: String, turn: String, item: String, time: Int) throws -> AgentLogBatch {
      let url = try file(.codex, name: name + ".jsonl")
      try write([json(["type": "event_msg", "timestamp": stamp(time), "payload": ["thread_id": thread,
        "turn_id": turn, "type": "item_completed", "item": ["id": item, "type": "UserMessage",
          "content": [["type": "text", "text": "Invented namespace instruction"]]]]])], to: url)
      let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
      return try AgentLogFiles.read(source, tool: .codex, position: nil, at: 300)
    }
    func commit(_ batch: AgentLogBatch) throws {
      try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
    }
    try commit(read("invented-digest", thread: raw, turn: "invented-turn", item: "invented-item", time: 200))
    try commit(read("invented-literal", thread: "native", turn: "sha256", item: digest, time: 202))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence"), 2)
    let preview = try store.previewDeletion(in: TimeRange(200, 201))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    try commit(read("invented-digest-copy", thread: raw, turn: "invented-turn", item: "invented-item", time: 204))
    try commit(read("invented-literal-copy", thread: "native", turn: "sha256", item: digest, time: 206))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence WHERE source_id=?", [.key(literalKey)]), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_events WHERE ts=204"), 0)
  }

  func testNinthMainSchemaNineNativeTombstonesSurviveAdoption() throws {
    // Main 45312a9 had schema 9, literal source_id keys and source-scoped Codex
    // refusals. Populate that shape directly, including an already-forgotten range.
    var cases = 0
    for size in [100, 4079, 4080, 4090, 4095, 4096, 4097, 4200, 8192, 1 << 20] {
      let raw = String(repeating: "x", count: size)
      for field in ["uuid", "thread", "turn", "item"] {
        let base = root.appendingPathComponent("main-\(field)-\(size)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("invented.sqlite")
        var storage: ActivityStorage! = try ActivityStorage(url: url, appDataDirectory: base, databaseScope: .directory(base))
        let tool: AgentLogTool = field == "uuid" ? .claude : .codex
        let thread = field == "thread" ? raw : "invented-thread"
        let turn = field == "turn" ? raw : "invented-turn"
        let item = field == "item" ? raw : "invented-item"
        let old = tool == .claude ? "claude:" + raw : "codex:" + thread + ":" + turn + ":" + item
        try storage.connection.run("INSERT INTO forgotten_ranges VALUES(200,201)")
        try storage.connection.run("INSERT INTO forgotten_sources VALUES(?,?)", [.key("invented-old-source"), .key(old)])
        let native = AgentLogEventParser.claudeIdentity(raw)
        let reservedLiteral = tool == .claude && native.hasPrefix("claude:native:sha256:") ? String(native.dropFirst(7)) : nil
        if reservedLiteral != nil {
          try storage.connection.run("INSERT INTO forgotten_sources VALUES(?,?)", [.key("invented-old-source"), .key(native)])
        }
        let codexNative = AgentLogEventParser.codexIdentity(thread: AgentLogEventParser.rawIdentity(thread), turn: turn, item: item)
        let codexLiteral = tool == .codex && codexNative.hasPrefix("codex:native:sha256:")
          ? AgentLogEventParser.codexIdentity(thread: "native", turn: "sha256", item: String(codexNative.dropFirst("codex:native:sha256:".count))) : nil
        if codexLiteral != nil {
          try storage.connection.run("INSERT INTO forgotten_sources VALUES(?,?)", [.key("invented-old-source"), .key(codexNative)])
        }
        // These relations did not exist on main. The normal schema adoption creates them.
        for name in ["agent_prompt_lineage", "agent_prompt_edges", "agent_prompt_aliases"] {
          try storage.connection.run("DROP \(name == "agent_prompt_lineage" ? "VIEW" : "TABLE") \(name)")
        }
        try storage.connection.run("PRAGMA user_version=9")
        storage = nil
        storage = try ActivityStorage(url: url, appDataDirectory: base, databaseScope: .directory(base))
        if let reservedLiteral {
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM forgotten_sources WHERE source_id=?",
            [.key("claude:" + reservedLiteral)]), 1)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM forgotten_sources WHERE source_id=?", [.key(native)]), 1)
        }
        if codexLiteral != nil {
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM forgotten_sources WHERE source_id=?", [.key(codexNative)]), 1)
        }
        var state = AgentLogState()
        let line: String
        if tool == .claude {
          line = try json(["type": "user", "sessionId": "invented-session", "uuid": raw, "timestamp": stamp(202),
            "message": ["role": "user", "content": "Invented migrated instruction"]])
        } else {
          line = try json(["type": "event_msg", "timestamp": stamp(202), "payload": ["thread_id": thread,
            "turn_id": turn, "type": "item_completed", "item": ["id": item, "type": "UserMessage",
              "content": [["type": "text", "text": "Invented migrated instruction"]]]]])
        }
        let bytes = Data(line.utf8)
        let event = try XCTUnwrap(AgentLogEventParser.parse(bytes, byteCount: bytes.count, offset: 0, observedAt: 300,
          tool: tool, file: "invented-new-source.jsonl", state: &state, logsRelativePath: nil, fingerprint: { _ in "invented" }))
        XCTAssertTrue(try storage.legacyLogAdapter.refused(event.legacyRefusal))
        let position = LogPosition(path: "invented-new-source.jsonl", device: 1, inode: 2, offset: bytes.count + 1,
          state: try state.encoded(), seenAt: 300)
        try storage.appendLogEvents([event], evidence: [try XCTUnwrap(event.prompt)], position: position)
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 0, "\(field) \(size)")
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events"), 0)
        XCTAssertEqual(try storage.connection.integer("PRAGMA user_version"), SQLiteConnection.schemaVersion)
        storage = nil
        storage = try ActivityStorage(url: url, appDataDirectory: base, databaseScope: .directory(base))
        try storage.appendLogEvents([event], evidence: [try XCTUnwrap(event.prompt)], position: position)
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 0)
        storage = nil
        cases += 1
      }
    }
    print("Ninth main adoption matrix: \(cases) literal tombstones, zero restored evidence/events, reopen verified")
  }

  func testNinthMainExistingEvidenceCopyAndForgetAfterAdoption() throws {
    var cases = 0
    for size in [100, 4079, 4080, 4090, 4095, 4096, 4097, 4200, 8192, 1 << 20] {
      let raw = String(repeating: "x", count: size)
      for field in ["uuid", "thread", "turn", "item"] {
        let base = root.appendingPathComponent("existing-\(field)-\(size)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("invented.sqlite")
        var storage: ActivityStorage! = try ActivityStorage(url: url, appDataDirectory: base, databaseScope: .directory(base))
        try storage.saveSettings(StorageSettings(), at: 0)
        let tool: AgentLogTool = field == "uuid" ? .claude : .codex
        let thread = field == "thread" ? raw : "invented-thread"
        let turn = field == "turn" ? raw : "invented-turn"
        let item = field == "item" ? raw : "invented-item"
        let old = tool == .claude ? "claude:" + raw : "codex:" + thread + ":" + turn + ":" + item
        let canonical = tool == .claude ? AgentLogEventParser.claudeIdentity(raw)
          : AgentLogEventParser.codexIdentity(thread: AgentLogEventParser.rawIdentity(thread), turn: turn, item: item)
        try storage.connection.run("INSERT INTO evidence(ts,kind,source,source_id,document_key,project,text) VALUES(200,'prompt','invented-existing-source',?,'','invented-project','Invented retained instruction')", [.key(old)])
        let hasLiteral = canonical.hasPrefix(tool.rawValue + ":native:sha256:")
        let literalKey: String? = hasLiteral ? (tool == .claude
          ? AgentLogEventParser.claudeIdentity(String(canonical.dropFirst(7)))
          : AgentLogEventParser.codexIdentity(thread: "native", turn: "sha256", item: String(canonical.dropFirst("codex:native:sha256:".count)))) : nil
        if hasLiteral {
          try storage.connection.run("INSERT INTO evidence(ts,kind,source,source_id,document_key,project,text) VALUES(202,'prompt','invented-existing-source',?,'','','Invented separate literal instruction')", [.key(canonical)])
        }
        for name in ["agent_prompt_lineage", "agent_prompt_edges", "agent_prompt_aliases"] {
          try storage.connection.run("DROP \(name == "agent_prompt_lineage" ? "VIEW" : "TABLE") \(name)")
        }
        try storage.connection.run("PRAGMA user_version=9")
        storage = nil
        storage = try ActivityStorage(url: url, appDataDirectory: base, databaseScope: .directory(base))
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence WHERE ts=200 AND source_id=? AND project='invented-project' AND text='Invented retained instruction'", [.key(old)]), 1)
        if let literalKey {
          XCTAssertNotEqual(canonical, literalKey)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence WHERE source_id=? AND ts=202", [.key(canonical)]), 1)
        }
        func commit(_ time: Int) throws {
          let line: String
          if tool == .claude {
            line = try json(["type": "user", "sessionId": "invented-session", "uuid": raw, "timestamp": stamp(time),
              "message": ["role": "user", "content": "Invented retained instruction"]])
          } else {
            line = try json(["type": "event_msg", "timestamp": stamp(time), "payload": ["thread_id": thread,
              "turn_id": turn, "type": "item_completed", "item": ["id": item, "type": "UserMessage",
                "content": [["type": "text", "text": "Invented retained instruction"]]]]])
          }
          let bytes = Data(line.utf8)
          var state = AgentLogState()
          let event = try XCTUnwrap(AgentLogEventParser.parse(bytes, byteCount: bytes.count, offset: time, observedAt: 300,
            tool: tool, file: "invented-adopted-copy.jsonl", state: &state, logsRelativePath: nil, fingerprint: { _ in "invented" }))
          try storage.appendLogEvents([event], evidence: [try XCTUnwrap(event.prompt)], position: LogPosition(
            path: "invented-adopted-copy.jsonl", device: 1, inode: 2, offset: time + bytes.count + 1, state: try state.encoded(), seenAt: 300))
        }
        try commit(202)
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), hasLiteral ? 2 : 1)
        let preview = try storage.previewDeletion(in: TimeRange(200, 201))
        try storage.deleteRecords(in: preview.range, confirmation: preview.confirmation)
        storage = nil
        storage = try ActivityStorage(url: url, appDataDirectory: base, databaseScope: .directory(base))
        try commit(204)
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence WHERE ts=200"), 0)
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), hasLiteral ? 1 : 0)
        // The already-acquired physical occurrence at 202 is outside the approved range.
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events"), 1)
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE ts=204"), 0)
        storage = nil
        cases += 1
      }
    }
    print("Ninth existing-main matrix: \(cases) cases, existing content preserved, copy deduplicated, post-adoption forget permanent")
  }

  func testNinthIdentityDomainsAndSessionRegistrySweep() throws {
    let registry = AgentLogFiles.ownSources(appDataDirectory: root)
    for size in [100, 4079, 4080, 4090, 4095, 4096, 4097, 4200, 8192, 1 << 20] {
      let raw = String(repeating: "x", count: size)
      let key = AgentLogEventParser.rawIdentity(raw)
      XCTAssertEqual(AgentLogEventParser.safeIdentity(key), key)
      for tool in AgentLogTool.allCases {
        try registry.registerSession(raw, tool: tool)
        XCTAssertTrue(try registry.containsSession(AgentLogIdentityCodec.session(key), tool: tool))
        var state = AgentLogState(); state.session = AgentLogIdentityCodec.session(key); state.ownershipSession = AgentLogIdentityCodec.session(key); state.ownedSession = AgentLogIdentityCodec.session(key)
        let reopened = try AgentLogState.decode(state.encoded())
        XCTAssertEqual(reopened.session?.storedKey, key); XCTAssertEqual(reopened.ownershipSession?.storedKey, key); XCTAssertEqual(reopened.ownedSession?.storedKey, key)
        try store.purgeOwnLogSession(AgentLogIdentityCodec.session(key), tool: tool)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE tool=? AND session_id=?", [.key(tool.rawValue), .key(key)]), 1)
      }
      if key != raw {
        XCTAssertNotEqual(AgentLogEventParser.rawIdentity(key), key)
        XCTAssertFalse(try registry.containsSession(key, tool: .claude))
      }
      let native = AgentLogEventParser.claudeIdentity(raw)
      if native.hasPrefix("claude:native:sha256:") {
        XCTAssertNotEqual(AgentLogEventParser.claudeIdentity(String(native.dropFirst(7))), native)
      }
      let codex = AgentLogEventParser.codexIdentity(thread: key, turn: "invented-turn", item: raw)
      XCTAssertNotEqual(AgentLogEventParser.codexIdentity(thread: "invented", turn: "invented", item: String(codex.dropFirst(6))), codex)
    }
    XCTAssertNotEqual(AgentLogEventParser.codexIdentity(thread: "a:b", turn: "c", item: "d"),
      AgentLogEventParser.codexIdentity(thread: "a", turn: "b:c", item: "d"))
  }

  func testNinthNestingLimitCollectsMaskedOccurrenceWithoutProof() throws {
    for depth in [65536, 262144, 1048576] {
      let text = "{\"originator\":\"ActivityProbe\",\"ignored\":" + String(repeating: "[", count: depth)
        + "0" + String(repeating: "]", count: depth) + ",\"sessionId\":\"invented-session\",\"api_key\":\"invented-secret\"}"
      var scanner = AgentLogMetadata()
      for byte in text.utf8 { scanner.consume(byte) }
      XCTAssertFalse(scanner.complete); XCTAssertFalse(scanner.ownMarker); XCTAssertTrue(scanner.exceededNestingLimit)
      XCTAssertNil(scanner.explicitSession(tool: .claude))
      let checkpoint = try JSONEncoder().encode(scanner)
      XCTAssertLessThan(checkpoint.count, 2048)
      let reopened = try JSONDecoder().decode(AgentLogMetadata.self, from: checkpoint)
      XCTAssertTrue(reopened.exceededNestingLimit)
      for tool in AgentLogTool.allCases {
        let url = try file(tool, name: "invented-depth-\(depth).jsonl")
        try Data((text + "\n").utf8).write(to: url)
        let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
        let batch = try AgentLogFiles.read(source, tool: tool, position: nil, at: 300)
        XCTAssertEqual(batch.position.offset, text.utf8.count + 1)
        let event = try XCTUnwrap(batch.events.first)
        XCTAssertTrue(event.flags.contains("metadataTooDeep")); XCTAssertEqual(event.parseStatus, "invalidJSON")
        XCTAssertFalse(event.payload.contains("invented-secret")); XCTAssertNil(event.prompt); XCTAssertTrue(event.identities.isEmpty)
        try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
      }
      print("Ninth nesting: depth=\(depth), checkpointBytes=\(checkpoint.count), masked occurrences=2, ownershipProof=false")
    }
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_events WHERE flags LIKE '%metadataTooDeep%'"), 6)
    for depth in [511, 512, 513] {
      let text = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
      var scanner = AgentLogMetadata()
      for byte in text.utf8 { scanner.consume(byte) }
      XCTAssertEqual(scanner.complete, depth <= 512)
      XCTAssertEqual(AgentLogJSON.object(Data(text.utf8)) != nil, depth <= 512)
    }
  }

  func testNinthNumericGrammarVersusDecoderRepresentation() throws {
    // JSON grammar has no IEEE numeric range limit. Valid out-of-range numbers must not
    // discard an otherwise valid object or disagree with the validating metadata path.
    for token in ["1e999", "1e+0001", "-1e999", "1e-999"] {
      for text in [token, "{\"type\":\"user\",\"sessionId\":\"invented\",\"ignored\":" + token + "}"] {
        var scanner = AgentLogMetadata()
        for byte in text.utf8 { scanner.consume(byte) }
        XCTAssertTrue(scanner.complete)
        XCTAssertNotNil(AgentLogJSON.object(Data(text.utf8)), text)
        XCTAssertNotEqual(AgentLogEventParser.maskedPayload(text), "null")
      }
      let text = "{\"type\":\"user\",\"uuid\":\"invented-number-item\",\"timestamp\":\"" + stamp(200)
        + "\",\"sessionId\":" + token + ",\"originator\":" + token
        + ",\"api_key\":\"invented-secret\",\"message\":{\"role\":\"user\",\"content\":\"Invented numeric instruction\"}}"
      let bytes = Data(text.utf8)
      var scanner = AgentLogMetadata()
      for byte in bytes { scanner.consume(byte) }
      XCTAssertNil(scanner.explicitSession(tool: .claude)); XCTAssertFalse(scanner.ownMarker)
      var state = AgentLogState()
      let event = try XCTUnwrap(AgentLogEventParser.parse(bytes, byteCount: bytes.count, offset: 0, observedAt: 300,
        tool: .claude, file: "invented-number.jsonl", state: &state, logsRelativePath: nil, metadata: scanner,
        fingerprint: { _ in "invented" }))
      XCTAssertNotNil(event.prompt); XCTAssertNil(event.explicitSession); XCTAssertNil(state.session)
      XCTAssertFalse(event.payload.contains("invented-secret")); XCTAssertEqual(event.parseStatus, "parsed")
    }
  }
}
