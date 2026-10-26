@testable import Core
import Foundation
@testable import Inbound
import SQLite3
@testable import Storage
import XCTest

private final class EleventhWork {
  var ticks = 0
}

extension AgentLogTests {
  private func eleventhRecord(_ tool: AgentLogTool, thread: String, turn: String = "invented-turn",
    item: String = "invented-item", time: Int = 200, role: String = "user", originator: String? = nil,
    depth: Int = 0, inherited: Bool = false) throws -> String {
    var line: [String: Any]
    if tool == .claude {
      line = ["type": role, "sessionId": thread, "uuid": item, "timestamp": stamp(time),
        "message": ["role": role, "content": "Invented eleventh instruction"]]
    } else {
      var payload: [String: Any] = ["type": "item_completed", "turn_id": turn,
        "item": ["id": item, "type": role == "user" ? "UserMessage" : "AssistantMessage", "role": role,
          "content": [["type": "text", "text": "Invented eleventh instruction"]]]]
      if !inherited { payload["thread_id"] = thread }
      line = ["type": "event_msg", "timestamp": stamp(time), "payload": payload]
    }
    if let originator {
      if depth == 0 { line["originator"] = originator }
      else {
        var payload = line["payload"] as? [String: Any] ?? [:]
        if depth == 1 { payload["originator"] = originator }
        else {
          var item = payload["item"] as? [String: Any] ?? [:]
          item["originator"] = originator; payload["item"] = item
        }
        line["payload"] = payload
      }
    }
    return try json(line)
  }
  private func eleventhRead(_ lines: [String], tool: AgentLogTool, base: URL, name: String,
    position: LogPosition? = nil) throws -> AgentLogBatch {
    let url = base.appendingPathComponent(name + ".jsonl")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    let source = try XCTUnwrap(AgentLogFiles.listing([base.path]).files.first { $0.path == url.path })
    var batch = try AgentLogFiles.read(source, tool: tool, position: position, at: 300,
      ownSources: AgentLogFiles.ownSources(appDataDirectory: base))
    while batch.position.offset < source.size || batch.ownershipDeferred {
      let next = try AgentLogFiles.read(source, tool: tool, position: batch.position, at: 300,
        ownSources: AgentLogFiles.ownSources(appDataDirectory: base))
      batch.events += next.events; batch.evidence += next.evidence
      batch.position = next.position; batch.ownershipDeferred = next.ownershipDeferred
    }
    return batch
  }
  private func eleventhSnapshot(_ storage: ActivityStorage, table: String) throws -> [Data] {
    var values: [Data] = []
    try storage.connection.rows("SELECT * FROM \(table) ORDER BY 1,2") { row in
      var bytes = Data()
      for column in 0..<sqlite3_column_count(row) {
        bytes.append(UInt8(sqlite3_column_type(row, column)))
        let count = sqlite3_column_bytes(row, column)
        bytes.append(Data("\(count):".utf8))
        if let data = sqlite3_column_blob(row, column) { bytes.append(Data(bytes: data, count: Int(count))) }
      }
      values.append(bytes)
    }
    return values
  }
  func testEleventhManyToOneAdoptionPreservesHistoricalBytesAndTypes() throws {
    var runs = 0
    for field in ["uuid", "thread", "turn", "item"] {
      for pair in [("invented-a", "invented-\\u0061"),
        ("{\"ordinary\":\"invented\"}", "{ \"ordinary\" : \"invented\" }"),
        ("invented-a", "invented-b")] {
        for reverse in [false, true] {
          for collision in [false, true] {
            let base = root.appendingPathComponent("many-\(runs)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let database = base.appendingPathComponent("invented.sqlite")
            var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
            let raw = reverse ? [pair.1, pair.0] : [pair.0, pair.1]
            for (index, value) in raw.enumerated() {
              let key = field == "uuid" ? "claude:" + value : "codex:"
                + (field == "thread" ? value : "invented-thread") + ":"
                + (field == "turn" ? value : "invented-turn") + ":"
                + (field == "item" ? value : "invented-item")
              try storage.connection.run("INSERT INTO evidence(id,ts,kind,source,source_id,document_key,project,text) VALUES(?,?,'prompt','invented-source',?,'invented-document','invented-project',?)",
                [.integer(index + 1), .integer(200 + index), .key(key), .text("Invented body \(index)")])
            }
            if collision {
              let canonical = field == "uuid" ? AgentLogEventParser.claudeIdentity(pair.1)
                : AgentLogEventParser.codexIdentity(thread: AgentLogEventParser.rawIdentity(field == "thread" ? pair.1 : "invented-thread"),
                    turn: field == "turn" ? pair.1 : "invented-turn", item: field == "item" ? pair.1 : "invented-item")
              try storage.connection.run("INSERT OR IGNORE INTO evidence(id,ts,kind,source,source_id,document_key,project,text) VALUES(3,202,'prompt','invented-source',?,'','','Invented unchanged collision')", [.key(canonical)])
            }
            try storage.connection.run("INSERT INTO forgotten_sources VALUES('invented-source','codex:invented:old:refusal')")
            try storage.connection.run("INSERT INTO agent_log_refusals VALUES('codex',1,2,3,'invented')")
            let tables = ["evidence", "forgotten_sources", "agent_log_refusals"]
            let before = try tables.map { try eleventhSnapshot(storage, table: $0) }
            try storage.connection.run("PRAGMA user_version=9")
            try storage.connection.run("CREATE TRIGGER invented_adoption_abort BEFORE INSERT ON agent_log_legacy_evidence_keys BEGIN SELECT RAISE(ABORT,'invented'); END")
            XCTAssertThrowsError(try storage.connection.createSchema())
            XCTAssertEqual(try storage.connection.integer("PRAGMA user_version"), 9)
            for (table, snapshot) in zip(tables, before) { XCTAssertEqual(try eleventhSnapshot(storage, table: table), snapshot) }
            try storage.connection.run("DROP TRIGGER invented_adoption_abort")
            storage = nil
            for _ in 0..<2 {
              storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
              for (table, snapshot) in zip(tables, before) { XCTAssertEqual(try eleventhSnapshot(storage, table: table), snapshot, "\(field) \(runs)") }
              storage = nil
            }
            runs += 1
          }
        }
      }
    }
    print("Eleventh many-to-one adoption: \(runs) both-order/collision cases, two reopens, byte/type-identical historical evidence and refusals")
  }
  func testEleventhDigestReceiptsDoNotPersistEscapedSecretsAfterForget() throws {
    let secret = "sk-proj-" + String(repeating: "v", count: 48)
    let escaped = secret.unicodeScalars.map { String(format: "\\u%04x", $0.value) }.joined()
    let spellings = [escaped, escaped.replacingOccurrences(of: "\\", with: "\\\\"), "\"" + escaped + "\""]
    var runs = 0
    for field in ["uuid", "commandUuid", "source_uuid", "attachment.source_uuid", "thread", "turn", "item", "header.id", "header.session_id"] {
      for value in spellings {
        let base = root.appendingPathComponent("secret-\(runs)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let database = base.appendingPathComponent("invented.sqlite")
        let tool: AgentLogTool = ["uuid", "commandUuid", "source_uuid", "attachment.source_uuid"].contains(field) ? .claude : .codex
        var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
        try storage.saveSettings(StorageSettings(), at: 0)
        let thread = field == "thread" || field.hasPrefix("header.") ? value : "invented-thread"
        let turn = field == "turn" ? value : "invented-turn"
        let item = tool == .claude || field == "item" ? value : "invented-item"
        let old = tool == .claude ? "claude:" + value : "codex:" + thread + ":" + turn + ":" + item
        try storage.connection.run("INSERT INTO evidence(id,ts,kind,source,source_id,document_key,project,text) VALUES(1,200,'prompt','invented-original',?,'','','Invented original')", [.key(old)])
        let before = try eleventhSnapshot(storage, table: "evidence")
        try storage.connection.run("PRAGMA user_version=9"); storage = nil
        storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
        XCTAssertEqual(try eleventhSnapshot(storage, table: "evidence"), before)
        for table in ["agent_log_legacy_evidence_keys", "agent_log_legacy_refusals", "agent_log_legacy_compatibility", "agent_log_content_keys"] {
          for row in try eleventhSnapshot(storage, table: table) {
            XCTAssertNil(row.range(of: Data(escaped.utf8))); XCTAssertNil(row.range(of: Data(secret.utf8)))
          }
        }
        let preview = try storage.previewDeletion(in: TimeRange(200, 201))
        try storage.deleteRecords(in: preview.range, confirmation: preview.confirmation)
        storage = nil
        storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
        for table in ["forgotten_sources", "agent_log_legacy_refusals", "agent_log_legacy_compatibility"] {
          for row in try eleventhSnapshot(storage, table: table) {
            XCTAssertNil(row.range(of: Data(escaped.utf8))); XCTAssertNil(row.range(of: Data(secret.utf8)))
          }
        }
        var lines: [String] = []
        if field.hasPrefix("header.") {
          lines.append(try json(["type": "session_meta", "payload": [String(field.dropFirst(7)): thread]]))
        }
        if tool == .claude {
          var record: [String: Any] = ["type": "user", "timestamp": stamp(204), "uuid": value,
            "message": ["role": "user", "content": "Invented later"]]
          if field == "attachment.source_uuid" {
            record["type"] = "attachment"; record["attachment"] = ["type": "queued_command", "humanTurn": true, "source_uuid": value, "prompt": "Invented later"]
          } else { record[field] = value }
          lines.append(try json(record))
        } else { lines.append(try eleventhRecord(tool, thread: thread, turn: turn, item: item, time: 204, inherited: field.hasPrefix("header."))) }
        let batch = try eleventhRead(lines, tool: tool, base: base, name: "invented-later")
        try storage.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 0, "secret \(runs)")
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE ts=204"), 0, "secret event \(runs)")
        if let wal = try? Data(contentsOf: URL(fileURLWithPath: database.path + "-wal")) {
          XCTAssertNil(wal.range(of: Data(escaped.utf8))); XCTAssertNil(wal.range(of: Data(secret.utf8)))
        }
        storage = nil; runs += 1
      }
    }
    print("Eleventh secret receipts: \(runs) key/escape cases, untouched historical bytes, future forget/restart refusal, no reversible secret in new rows/WAL")
  }
  func testEleventhExactOriginatorAcrossEveryRoleDepthCheckpointAndRollback() throws {
    var runs = 0
    for marker in [AgentWindowIdentity.codexOriginator, AgentWindowIdentity.codexPlanOriginator] {
    for tool in AgentLogTool.allCases {
      for role in ["user", "assistant", "system", "tool"] {
        for depth in 0...2 {
          for variant in 0...3 {
            let base = root.appendingPathComponent("origin-\(runs)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let database = base.appendingPathComponent("invented.sqlite")
            var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
            try storage.saveSettings(StorageSettings(), at: 0)
            let foreign = try eleventhRead([eleventhRecord(tool, thread: "invented-session", item: "invented-before")], tool: tool, base: base, name: "invented-foreign")
            try storage.appendLogEvents(foreign.events, evidence: foreign.evidence, position: foreign.position)
            let beforeCursor = try XCTUnwrap(storage.logPosition(path: foreign.position.path))
            let escaped = (marker.first == "a" ? "\\u0061" : "\\u0041") + marker.dropFirst()
            let value = variant == 0 ? escaped : variant == 1 ? escaped.replacingOccurrences(of: "\\", with: "\\\\") : variant == 2 ? marker : "invented-foreign"
            var line = try eleventhRecord(tool, thread: "invented-session", item: "invented-after", time: 202, role: role, originator: value, depth: depth)
            // Genuine JSON escapes decode once to the exact own marker.
            if variant == 2 { line = line.replacingOccurrences(of: marker, with: escaped) }
            var scanner = AgentLogMetadata()
            for byte in line.utf8 { scanner.consume(byte) }
            XCTAssertEqual(scanner.ownMarker, variant == 2)
            let restored = try JSONDecoder().decode(AgentLogMetadata.self, from: JSONEncoder().encode(scanner))
            XCTAssertEqual(restored.ownMarker, variant == 2)
            var recovery = AgentLogState()
            restored.apply(tool: tool, file: "invented-recovery", state: &recovery, fingerprint: { _ in "invented" })
            XCTAssertEqual(recovery.ownedSession != nil, variant == 2)
            let prepared = try eleventhRead([line], tool: tool, base: base, name: "invented-discovery")
            try storage.connection.run("CREATE TRIGGER invented_abort BEFORE INSERT ON log_positions BEGIN SELECT RAISE(ABORT,'invented'); END")
            XCTAssertThrowsError(try storage.appendLogEvents(prepared.events, evidence: prepared.evidence, position: prepared.position))
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 1)
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions"), 0)
            try storage.connection.run("DROP TRIGGER invented_abort")
            try storage.appendLogEvents(prepared.events, evidence: prepared.evidence, position: prepared.position)
            storage = nil
            storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions"), variant == 2 ? 1 : 0)
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), variant == 2 ? 0 : (role == "user" ? 2 : 1))
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events"), variant == 2 ? 0 : 2)
            if variant != 2 { XCTAssertEqual(try storage.logPosition(path: foreign.position.path)?.offset, beforeCursor.offset) }
            // Prepared foreign batches remain foreign after the same nonmatching marker is known.
            try storage.appendLogEvents(foreign.events, evidence: foreign.evidence, position: foreign.position)
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events"), variant == 2 ? 0 : 2)
            storage = nil; runs += 1
          }
        }
      }
    }
    }
    print("Eleventh originator matrix: \(runs) tool/role/depth/escape cases, validating checkpoint, known/late/prepared/abort/retry/reopen controls")
  }
  func testEleventhNativeSubjectsCannotAcquireOwnedSessionByDisplayNormalization() throws {
    let registry = AgentLogFiles.ownSources(appDataDirectory: root)
    for own in ["invented-a", "{\"ordinary\":\"invented\"}", " "] {
      let other = own == "invented-a" ? "invented-\\u0061" : own == " " ? "\\u0020" : "{ \"ordinary\" : \"invented\" }"
      for tool in AgentLogTool.allCases {
        try registry.registerSession(own, tool: tool)
        XCTAssertFalse(try registry.containsSession(other, tool: tool))
        XCTAssertNotEqual(AgentLogEventParser.rawIdentity(own), AgentLogEventParser.rawIdentity(other))
        XCTAssertNotEqual(AgentLogEventParser.claudeIdentity(own), AgentLogEventParser.claudeIdentity(other))
        let batch = try eleventhRead([eleventhRecord(tool, thread: other)], tool: tool, base: root, name: "invented-subject-\(tool)-\(own.count)")
        XCTAssertEqual(batch.events.count, 1); XCTAssertEqual(batch.evidence.count, 1)
      }
    }
  }
  func testEleventhInheritedUnicodeWhitespaceLegacyRefusalAndRecoveryClassification() throws {
    let raw = String(repeating: "\u{a0}", count: 4096)
    try store.connection.run("INSERT INTO forgotten_sources VALUES('invented-original',?)", [.key("codex:" + raw + ":invented-turn:invented-item")])
    try store.connection.run("INSERT INTO forgotten_sources VALUES('invented-claude-original','claude:[secret]')")
    try store.connection.run("PRAGMA user_version=9")
    let database = root.appendingPathComponent("invented.sqlite")
    store = nil
    store = try ActivityStorage(url: database, appDataDirectory: root, databaseScope: .directory(root))
    let lines = [try json(["type": "session_meta", "timestamp": stamp(190), "payload": ["id": raw]]),
      try eleventhRecord(.codex, thread: raw, time: 204, inherited: true)]
    let batch = try eleventhRead(lines, tool: .codex, base: root, name: "invented-whitespace")
    try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_events WHERE role='user'"), 0)
    let foreignRaw = "{ \"ordinary\" : \"invented\" }"
    let foreign = try eleventhRead([json(["type": "session_meta", "timestamp": stamp(190), "payload": ["id": foreignRaw]]),
      eleventhRecord(.codex, thread: foreignRaw, item: "invented-unrelated-item", time: 206, inherited: true)],
      tool: .codex, base: root, name: "invented-foreign-tool")
    try store.appendLogEvents(foreign.events, evidence: foreign.evidence, position: foreign.position)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence"), 1,
      "a known Claude tombstone cannot refuse an unrelated inherited Codex subject")
    for tool in AgentLogTool.allCases {
      let foreign = "\\u0041ctivityProbe"
      let line = try eleventhRecord(tool, thread: "invented-recovery-session", originator: foreign)
      let url = root.appendingPathComponent("invented-recovery-\(tool).jsonl")
      try Data((line + "\n").utf8).write(to: url)
      let file = try XCTUnwrap(AgentLogFiles.listing([root.path]).files.first { $0.path == url.path })
      var old = AgentLogState(); old.metadataVersion = 0; old.tool = tool.rawValue
      old.ownWorkingFolder = true; old.ownedSession = AgentLogIdentityCodec.session("invented-recovery-session"); old.ignoredSession = .ownWindow
      let position = LogPosition(path: url.path, device: file.device, inode: file.inode, offset: 0, state: try old.encoded(), seenAt: 200)
      let recovered = try AgentLogFiles.read(file, tool: tool, position: position, at: 300,
        ownSources: AgentLogFiles.ownSources(appDataDirectory: root))
      XCTAssertEqual(recovered.events.count, 1); XCTAssertEqual(recovered.evidence.count, 1)
      XCTAssertNil(try AgentLogState.decode(recovered.position.state).ownedSession)
    }
  }
  func testEleventhIndexedLegacyWriterWorkAndPopulatedBenchmark() throws {
    var previous: [String: Int] = [:]
    for count in [10_000, 100_000] {
      let base = root.appendingPathComponent("benchmark-\(count)")
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      let database = base.appendingPathComponent("invented.sqlite")
      var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
      try storage.saveSettings(StorageSettings(), at: 0)
      try storage.connection.run("""
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<?)
        INSERT INTO forgotten_sources SELECT 'invented-old-source','codex:invented-unrelated-'||x||':turn:item' FROM n
        """, [.integer(count)])
      try storage.connection.run("PRAGMA user_version=9"); storage = nil
      storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
      try storage.connection.run("""
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<?)
        INSERT INTO agent_log_content_keys SELECT 'claude:invented-unrelated-'||x,-x FROM n
        """, [.integer(count)])
      // Masked historical content without a tombstone must not make a lossy
      // subject scan nonmatching content while checking permanent refusals.
      try storage.connection.run("""
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<?)
        INSERT INTO agent_log_legacy_compatibility SELECT '*','*','invented-unrelated-content-'||x FROM n
        """, [.integer(count)])
      for (subjectIndex, raw) in ["invented-short", String(repeating: "x", count: 8192), "{ \"ordinary\" : \"invented\" }"].enumerated() {
        for inherited in [true, false] {
          for restart in 0...1 {
            storage = nil
            storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
            var lines = [try json(["type": "session_meta", "timestamp": stamp(190), "payload": ["id": raw]])]
            for index in 0..<20 {
              lines.append(try eleventhRecord(.codex, thread: raw, item: "invented-item-\(index)", time: 200 + index, inherited: inherited))
            }
            let batch = try eleventhRead(lines, tool: .codex, base: base, name: "invented-\(raw.count)-\(inherited)-\(restart)")
            let work = EleventhWork()
            sqlite3_progress_handler(storage.connection.handle, 100, { context in
              Unmanaged<EleventhWork>.fromOpaque(context!).takeUnretainedValue().ticks += 1
              return 0
            }, Unmanaged.passUnretained(work).toOpaque())
            let start = Date()
            try storage.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
            let elapsed = Date().timeIntervalSince(start)
            sqlite3_progress_handler(storage.connection.handle, 0, nil, nil)
            let key = "\(raw.count)-\(inherited)-\(restart)"
            if let baseline = previous[key] { XCTAssertLessThanOrEqual(work.ticks, baseline + 20, "writer work grew with unrelated rows: \(key)") }
            else { previous[key] = work.ticks }
            XCTAssertLessThan(elapsed, 5, "20 records must not scan unrelated legacy rows")
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE source=?", [.key(AgentLogEventParser.pathIdentity(batch.position.path))]), 21)
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 20 * (subjectIndex + 1))
            print("Eleventh benchmark unrelated=\(count) subjectBytes=\(raw.utf8.count) inherited=\(inherited) restart=\(restart) events=21 writerSeconds=\(elapsed) vmHundreds=\(work.ticks)")
          }
        }
      }
      storage = nil
    }
  }
}
