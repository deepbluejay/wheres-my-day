@testable import Core
import Foundation
import SQLite3
@testable import Inbound
@testable import Storage
import XCTest

extension AgentLogTests {
  private func twelfthSnapshot(_ storage: ActivityStorage, _ table: String) throws -> [Data] {
    var result: [Data] = []
    try storage.connection.rows("SELECT * FROM \(table) ORDER BY 1,2") { row in
      var bytes = Data()
      for column in 0..<sqlite3_column_count(row) {
        bytes.append(UInt8(sqlite3_column_type(row, column)))
        let count = sqlite3_column_bytes(row, column)
        bytes.append(Data("\(count):".utf8))
        if let value = sqlite3_column_blob(row, column) { bytes.append(Data(bytes: value, count: Int(count))) }
      }
      result.append(bytes)
    }
    return result
  }
  private func twelfthRecord(_ tool: AgentLogTool, session: String, item: String) throws -> String {
    if tool == .claude {
      return try json(["type": "user", "sessionId": session, "uuid": item, "timestamp": stamp(200),
        "message": ["role": "user", "content": "Invented twelfth instruction"]])
    }
    return try json(["type": "event_msg", "timestamp": stamp(200), "payload": [
      "type": "item_completed", "thread_id": session, "turn_id": "invented-turn",
      "item": ["id": item, "type": "UserMessage", "content": [["type": "text", "text": "Invented twelfth instruction"]]]]])
  }
  private func twelfthHeader(_ tool: AgentLogTool, identity: Any?, own: Bool, alias: Bool = false) throws -> String {
    var fields: [String: Any] = ["cwd": own ? "/invented/" + AgentWindowIdentity.relativeFolder : "/invented/foreign"]
    if let identity { fields[tool == .claude ? "sessionId" : alias ? "session_id" : "id"] = identity }
    return try json(tool == .claude ? fields.merging(["type": "system"]) { $1 }
      : ["type": "session_meta", "payload": fields])
  }
  private func twelfthSource(_ url: URL) throws -> AgentLogFile {
    try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
  }
  private func twelfthCommit(_ batch: AgentLogBatch, storage: ActivityStorage) throws {
    try storage.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
  }
  func testTwelfthExactPhysicalPathsAcrossRestartAndBothOrders() throws {
    let secret = "sk-proj-" + String(repeating: "v", count: 48)
    let other = "sk-proj-" + String(repeating: "w", count: 48)
    let shapes = [("invented-a", "invented-\\u0061"), ("invented-" + secret, "invented-" + other),
      ("invented-\\u0073" + String(secret.dropFirst()), "invented-\\u0073" + String(other.dropFirst()))]
    var cases = 0
    for tool in AgentLogTool.allCases {
      for pair in shapes {
        for reverse in [false, true] {
          let base = root.appendingPathComponent("paths-\(cases)")
          try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
          let database = base.appendingPathComponent("invented.sqlite")
          var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
          try storage.saveSettings(StorageSettings(), at: 0)
          for (i, name) in [pair.0, pair.1].enumerated() {
            try write([twelfthRecord(tool, session: "invented-session-\(i)", item: "invented-item-\(i)")],
              to: base.appendingPathComponent(name + ".jsonl"))
          }
          let listed = try AgentLogFiles.listing([base.path]).files
          let files = reverse ? Array(listed.reversed()) : listed
          XCTAssertNotEqual(AgentLogEventParser.pathIdentity(files[0].path), AgentLogEventParser.pathIdentity(files[1].path))
          var acquired: [Int] = []
          for scan in 0..<3 {
            storage = nil
            storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
            var count = 0
            for file in files {
              let position = try storage.logPosition(path: file.path)
              if scan > 0 { XCTAssertTrue(AgentLogPolicy.continues(position, file: file)) }
              let batch = try AgentLogFiles.read(file, tool: tool, position: position, at: 300)
              count += batch.events.count
              try twelfthCommit(batch, storage: storage)
            }
            acquired.append(count)
          }
          XCTAssertEqual(acquired, [2, 0, 0])
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM log_positions"), 2)
          XCTAssertEqual(try storage.connection.integer("SELECT count(DISTINCT source) FROM agent_log_events"), 2)
          XCTAssertEqual(try storage.connection.integer("SELECT count(DISTINCT source) FROM agent_log_source_evidence"), 2)
          for table in ["log_positions", "agent_log_events", "agent_log_source_evidence", "agent_log_evidence_origins"] {
            let column = table == "log_positions" ? "path" : "source"
            try storage.connection.namedRows("SELECT \(column) AS value FROM \(table)") {
              let value = try $0.text("value")
              XCTAssertTrue(value.hasPrefix("activityprobe:path:sha256:"))
              XCTAssertFalse(value.contains(secret)); XCTAssertFalse(value.contains("\\u"))
            }
          }
          // Revoking one physical source cannot revoke its lossy-name neighbour.
          var own = try AgentLogState.decode(XCTUnwrap(storage.logPosition(path: files[0].path)).state)
          own.ownWorkingFolder = true; own.ignoredSession = .ownWindow
          try storage.appendLogEvents([], evidence: [], position: LogPosition(path: files[0].path,
            device: files[0].device, inode: files[0].inode, offset: files[0].size, state: own.encoded(), seenAt: 300))
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE source=?",
            [.key(AgentLogEventParser.pathIdentity(files[1].path))]), 1)
          storage = nil; cases += 1
        }
      }
    }
    XCTAssertEqual(cases, 12)
    print("Twelfth physical paths: 12 cases, both tools/orders, three restart scans [2,0,0], isolated source revocation")
  }
  func testTwelfthModernOwnReceiptsCannotAliasLegacyFallbackAfterInodeReuse() throws {
    for tool in AgentLogTool.allCases {
      for path in ["/invented/invented-\\u0061.jsonl",
        "/invented/invented-sk-proj-" + String(repeating: "v", count: 48) + ".jsonl"] {
        let base = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let storage = try ActivityStorage(url: base.appendingPathComponent("invented.sqlite"),
          appDataDirectory: base, databaseScope: .directory(base))
        try storage.saveSettings(StorageSettings(), at: 0)
        let other = AgentLogEventParser.safeIdentity(path)
        XCTAssertNotEqual(path, other)
        var owned = AgentLogState(); owned.tool = tool.rawValue; owned.ownWorkingFolder = true
        try storage.appendLogEvents([], evidence: [], position: LogPosition(path: other,
          device: 1, inode: 2, offset: 0, state: owned.encoded(), seenAt: 300))
        let line = try twelfthRecord(tool, session: "invented-foreign", item: "invented-foreign-item")
        var state = AgentLogState(); state.tool = tool.rawValue
        let event = try XCTUnwrap(AgentLogEventParser.parse(Data(line.utf8), byteCount: line.utf8.count,
          offset: 0, observedAt: 300, tool: tool, file: path, state: &state,
          logsRelativePath: nil, fingerprint: { _ in "invented" }))
        let result = try storage.appendLogEvents([event], evidence: event.prompt.map { [$0] } ?? [],
          position: LogPosition(path: path, device: 1, inode: 2, offset: line.utf8.count + 1,
            state: state.encoded(), seenAt: 300))
        XCTAssertEqual(result.stored, 1)
        XCTAssertEqual(try storage.agentLogGrowth().events, 1)
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions"), 0)
        XCTAssertNotEqual(AgentLogEventParser.pathIdentity(other), AgentLogEventParser.legacyPathIdentity(other))
      }
    }
  }
  func testTwelfthHistoricalCursorLookupAndPartialMetadataRecoveryNeverReplays() throws {
    var cases = 0
    for tool in AgentLogTool.allCases {
      for legacyMasked in [false, true] {
        for partial in [false, true] {
          let base = root.appendingPathComponent("historical-cursor-\(cases)")
          try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
          let url = base.appendingPathComponent("invented-\\u0061.jsonl")
          let lines = try [twelfthHeader(tool, identity: "invented-session", own: false),
            twelfthRecord(tool, session: "invented-session", item: "invented-historical")]
          try write(lines, to: url)
          let source = try twelfthSource(url)
          let database = base.appendingPathComponent("invented.sqlite")
          var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
          try storage.saveSettings(StorageSettings(), at: 0)
          let legacyKey = legacyMasked ? AgentLogEventParser.safeIdentity(url.path) : url.path
          let oldState: String
          if partial {
            var state = AgentLogState(); state.tool = tool.rawValue
            state.metadataRecoveryOffset = 1
            var scanner = AgentLogMetadata(); scanner.consume(123)
            state.metadataRecoveryScanner = scanner
            oldState = try state.encoded()
          } else {
            oldState = "{\"threadID\":\"invented-session\",\"folder\":\"/invented/foreign\",\"queued\":[]}"
          }
          try storage.connection.run("INSERT INTO log_positions VALUES(?,?,?,?,?,?)", [.key(legacyKey),
            .integer(source.device), .integer(source.inode), .integer(source.size), .text(oldState), .integer(299)])
          storage = nil
          for scan in 0..<2 {
            storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
            let position = try XCTUnwrap(storage.logPosition(path: url.path))
            XCTAssertEqual(position.device, source.device); XCTAssertEqual(position.inode, source.inode)
            XCTAssertEqual(position.offset, source.size)
            let batch = try AgentLogFiles.read(source, tool: tool, position: position, at: 300)
            XCTAssertTrue(batch.events.isEmpty); XCTAssertTrue(batch.evidence.isEmpty)
            XCTAssertEqual(batch.position.offset, source.size)
            XCTAssertEqual(try AgentLogState.decode(batch.position.state).session?.storedKey, "invented-session")
            try twelfthCommit(batch, storage: storage)
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM log_positions WHERE path=? AND state=? AND offset=?",
              [.key(legacyKey), .text(oldState), .integer(source.size)]), 1)
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM log_positions"), 2)
            XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events"), 0)
            if scan == 1 { XCTAssertNil(try AgentLogState.decode(batch.position.state).metadataRecoveryOffset) }
            storage = nil
          }
          cases += 1
        }
      }
    }
    XCTAssertEqual(cases, 8)
    print("Twelfth historical cursors: 8 raw/masked EOF/partial-recovery cases, two restarts, no replay, historical rows unchanged")
  }
  func testTwelfthUnusableSessionMarkersPreserveForeignSessions() throws {
    let identities: [Any?] = ["", " ", "\u{a0}", nil, NSNull(), 7]
    var cases = 0
    for tool in AgentLogTool.allCases {
      for alias in tool == .codex ? [false, true] : [false] {
        for identity in tool == .claude ? identities.filter({ $0 != nil }) : identities {
          for combined in [false, true] {
            for recovery in [false, true] {
              let base = root.appendingPathComponent("blank-\(cases)")
              try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
              let database = base.appendingPathComponent("invented.sqlite")
              var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
              try storage.saveSettings(StorageSettings(), at: 0)
              let foreign = base.appendingPathComponent("foreign.jsonl")
              try write([twelfthRecord(tool, session: "invented-foreign-A", item: "invented-foreign-item")], to: foreign)
              let foreignBatch = try AgentLogFiles.read(twelfthSource(foreign), tool: tool, position: nil, at: 300)
              try twelfthCommit(foreignBatch, storage: storage)
              let evidence = try storage.evidence(in: all)
              let cursor = try XCTUnwrap(storage.logPosition(path: foreign.path))
              let events = try storage.agentLogGrowth()
              let tables = ["evidence", "agent_log_events", "agent_log_payloads"]
              let before = try tables.map { try twelfthSnapshot(storage, $0) }
              let discovery = base.appendingPathComponent("discovery.jsonl")
              var lines = try [twelfthHeader(tool, identity: "invented-foreign-A", own: false),
                twelfthHeader(tool, identity: identity, own: combined, alias: alias)]
              if !combined { lines.append(try json(["type": "system", "cwd": "/invented/" + AgentWindowIdentity.relativeFolder])) }
              try write(lines, to: discovery)
              let source = try twelfthSource(discovery)
              var position: LogPosition?
              if recovery {
                var old = AgentLogState(); old.metadataVersion = 0; old.tool = tool.rawValue
                old.session = AgentLogIdentityCodec.session("invented-foreign-A"); old.ownershipSession = AgentLogIdentityCodec.session("invented-foreign-A")
                old.ownershipScanOffset = source.size
                position = LogPosition(path: source.path, device: source.device, inode: source.inode,
                  offset: source.size, state: try old.encoded(), seenAt: 299)
              }
              let registry = AgentLogFiles.ownSources(appDataDirectory: base)
              let batch = try AgentLogFiles.read(source, tool: tool, position: position, at: 300, ownSources: registry)
              let state = try AgentLogState.decode(batch.position.state)
              XCTAssertNil(state.ownedSession, "case \(cases)")
              XCTAssertTrue(state.ownWorkingFolder == true)
              XCTAssertFalse(try registry.containsSession("invented-foreign-A", tool: tool))
              // Exercise ordinary parsing and metadata replay independently of lookahead.
              var ordinary = AgentLogState(), replay = AgentLogState()
              for line in lines {
                _ = AgentLogEventParser.parse(Data(line.utf8), byteCount: line.utf8.count, offset: 0,
                  observedAt: 300, tool: tool, file: source.path, state: &ordinary, logsRelativePath: nil, fingerprint: { _ in "invented" })
                var scanner = AgentLogMetadata(); for byte in line.utf8 { scanner.consume(byte) }
                scanner.apply(tool: tool, file: source.path, state: &replay, fingerprint: { _ in "invented" })
              }
              XCTAssertNil(ordinary.ownedSession); XCTAssertNil(replay.ownedSession)
              try twelfthCommit(batch, storage: storage)
              storage = nil
              storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
              for (table, snapshot) in zip(tables, before) {
                XCTAssertEqual(try twelfthSnapshot(storage, table), snapshot)
              }
              XCTAssertEqual(try storage.evidence(in: all), evidence)
              XCTAssertEqual(try storage.agentLogGrowth().events, events.events)
              XCTAssertEqual(try storage.agentLogGrowth().payloads, events.payloads)
              XCTAssertEqual(try storage.logPosition(path: foreign.path)?.state, cursor.state)
              XCTAssertEqual(try storage.logPosition(path: foreign.path)?.offset, cursor.offset)
              XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions"), 0)
              XCTAssertFalse(try registry.containsSession("invented-foreign-A", tool: tool))
              storage = nil; cases += 1
            }
          }
        }
      }
    }
    XCTAssertEqual(cases, 68)
    print("Twelfth unusable identity: 68 cases, both tools/Codex aliases, blank/whitespace/null/nonstring and missing Codex IDs, combined/split own markers, fresh/recovery; ordinary/scanner/foreign preservation checked")
  }
  func testTwelfthUnusableExplicitThreadsClearInheritedOwnership() throws {
    var cases = 0
    for identity: Any in ["", " ", "\u{a0}", NSNull(), 7] {
      for ownOnBoundary in [false, true] {
        let header = try twelfthHeader(.codex, identity: "invented-foreign-A", own: false)
        var payload: [String: Any] = ["thread_id": identity]
        if ownOnBoundary { payload["originator"] = AgentWindowIdentity.codexOriginator }
        let boundary = try json(["type": "event_msg", "payload": payload])
        var lines = [header, boundary]
        if !ownOnBoundary { lines.append(try json(["type": "system", "originator": AgentWindowIdentity.codexOriginator])) }
        var ordinary = AgentLogState(), replay = AgentLogState()
        for line in lines {
          _ = AgentLogEventParser.parse(Data(line.utf8), byteCount: line.utf8.count, offset: 0,
            observedAt: 300, tool: .codex, file: "/invented/log.jsonl", state: &ordinary,
            logsRelativePath: nil, fingerprint: { _ in "invented" })
          var metadata = AgentLogMetadata(); for byte in line.utf8 { metadata.consume(byte) }
          metadata.apply(tool: .codex, file: "/invented/log.jsonl", state: &replay, fingerprint: { _ in "invented" })
        }
        XCTAssertNil(ordinary.session); XCTAssertNil(ordinary.ownedSession)
        XCTAssertNil(replay.session); XCTAssertNil(replay.ownedSession)
        let url = try file(.codex, name: "unusable-thread-\(cases).jsonl")
        try write(lines, to: url)
        let batch = try AgentLogFiles.read(twelfthSource(url), tool: .codex, position: nil, at: 300)
        XCTAssertNil(try AgentLogState.decode(batch.position.state).ownedSession)
        cases += 1
      }
    }
    XCTAssertEqual(cases, 10)
  }
  func testTwelfthHistoricalPhysicalReceiptsRevokeWithoutCopyingRawPaths() throws {
    var cases = 0
    for tool in AgentLogTool.allCases {
      for masked in [false, true] {
        for reverse in [false, true] {
          let base = root.appendingPathComponent("historical-physical-\(cases)")
          try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
          let database = base.appendingPathComponent("invented.sqlite")
          var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
          try storage.saveSettings(StorageSettings(), at: 0)
          let urls = [base.appendingPathComponent("invented-\\u0061.jsonl"), base.appendingPathComponent("invented-copy.jsonl")]
          for url in urls {
            try write([twelfthRecord(tool, session: "invented-owned", item: "invented-shared-item")], to: url)
            try twelfthCommit(AgentLogFiles.read(twelfthSource(url), tool: tool, position: nil, at: 300), storage: storage)
            let modern = AgentLogEventParser.pathIdentity(url.path)
            let historical = masked ? AgentLogEventParser.safeIdentity(url.path) : url.path
            // Simulate derived physical receipts produced before exact path keys.
            for (table, column) in [("agent_log_events", "source"), ("agent_log_source_evidence", "source"),
              ("agent_log_evidence_origins", "source"), ("log_positions", "path")] {
              try storage.connection.run("UPDATE \(table) SET \(column)=? WHERE \(column)=?", [.key(historical), .key(modern)])
            }
          }
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 1)
          storage = nil
          for url in reverse ? Array(urls.reversed()) : urls {
            storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
            let position = try XCTUnwrap(storage.logPosition(path: url.path))
            var state = try AgentLogState.decode(position.state)
            state.ownWorkingFolder = true; state.ignoredSession = .ownWindow
            // Physical ownership alone does not claim the shared session.
            state.ownedSession = nil; state.session = nil; state.ownershipSession = nil
            try storage.appendLogEvents([], evidence: [], position: LogPosition(path: url.path,
              device: position.device, inode: position.inode, offset: position.offset, state: state.encoded(), seenAt: 300))
            try storage.connection.namedRows("SELECT path FROM agent_log_tool_own_sources") {
              XCTAssertTrue(try $0.text("path").hasPrefix("activityprobe:path:sha256:"))
            }
            storage = nil
          }
          storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 0)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events"), 0)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_source_evidence"), 0)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_owned_evidence_origins"), 0)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions"), 0)
          storage = nil; cases += 1
        }
      }
    }
    XCTAssertEqual(cases, 8)
  }
  func testTwelfthHistoricalOwnSessionReceiptsRemainEffectiveWithoutRawPathCopies() throws {
    var cases = 0
    for tool in AgentLogTool.allCases {
      for masked in [false, true] {
        let base = root.appendingPathComponent("historical-session-\(cases)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let database = base.appendingPathComponent("invented.sqlite")
        var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
        try storage.saveSettings(StorageSettings(), at: 0)
        let url = base.appendingPathComponent("invented-\\u0061-sk-proj-" + String(repeating: "v", count: 48) + ".jsonl")
        try write([twelfthRecord(tool, session: "invented-owned", item: "invented-old-item")], to: url)
        let batch = try AgentLogFiles.read(twelfthSource(url), tool: tool, position: nil, at: 300)
        try twelfthCommit(batch, storage: storage)
        let modern = AgentLogEventParser.pathIdentity(url.path)
        let historical = masked ? AgentLogEventParser.safeIdentity(url.path) : Redaction.applyKnownSecrets(url.path).text
        for (table, column) in [("agent_log_events", "source"), ("agent_log_source_evidence", "source"),
          ("agent_log_evidence_origins", "source"), ("log_positions", "path")] {
          try storage.connection.run("UPDATE \(table) SET \(column)=? WHERE \(column)=?", [.key(historical), .key(modern)])
        }
        let marker = base.appendingPathComponent("marker.jsonl")
        try write([twelfthHeader(tool, identity: "invented-owned", own: true)], to: marker)
        try twelfthCommit(AgentLogFiles.read(twelfthSource(marker), tool: tool, position: nil, at: 300), storage: storage)
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_tool_own_sources WHERE path=?",
          [.key(AgentLogEventParser.legacyPathIdentity(historical))]), 1)
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 0)
        try FileManager.default.removeItem(at: base.appendingPathComponent(AgentLogOwnSources.folderName))
        storage = nil
        storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
        let line = try twelfthRecord(tool, session: "invented-other", item: "invented-new-item")
        var state = AgentLogState(); state.tool = tool.rawValue
        let event = try XCTUnwrap(AgentLogEventParser.parse(Data(line.utf8), byteCount: line.utf8.count,
          offset: batch.position.offset, observedAt: 300, tool: tool, file: url.path, state: &state,
          logsRelativePath: nil, fingerprint: { _ in "invented" }))
        try storage.appendLogEvents([event], evidence: event.prompt.map { [$0] } ?? [],
          position: LogPosition(path: url.path, device: batch.position.device, inode: batch.position.inode,
            offset: batch.position.offset + line.utf8.count + 1, state: state.encoded(), seenAt: 300))
        XCTAssertEqual(try storage.agentLogGrowth().events, 0)
        XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 0)
        try storage.connection.namedRows("SELECT path FROM agent_log_tool_own_sources") {
          XCTAssertTrue(try $0.text("path").hasPrefix("activityprobe:"))
          XCTAssertFalse(try $0.text("path").contains("\\u"))
        }
        storage = nil; cases += 1
      }
    }
    XCTAssertEqual(cases, 4)
  }
  func testTwelfthMainAdoptionAddsPhysicalOriginCapabilities() throws {
    let url = try file(.claude)
    try write([twelfthRecord(.claude, session: "invented-session", item: "invented-item")], to: url)
    try twelfthCommit(AgentLogFiles.read(twelfthSource(url), tool: .claude, position: nil, at: 300), storage: store)
    let before = try twelfthSnapshot(store, "evidence")
    try makeMainLogOrigin(store)
    store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    XCTAssertEqual(try twelfthSnapshot(store, "evidence"), before)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sqlite_master WHERE name IN ('agent_log_evidence_origins_source','agent_log_owned_evidence_origins','agent_log_owned_evidence_origin_cleanup')"), 3)
    var plans: [String] = []
    try store.connection.namedRows("EXPLAIN QUERY PLAN SELECT evidence_id FROM agent_log_evidence_origins WHERE tool=? AND device=? AND inode=? AND source=?",
      [.key("claude"), .integer(1), .integer(2), .key("invented")]) { plans.append(try $0.text("detail")) }
    XCTAssertTrue(plans.contains { $0.contains("COVERING INDEX agent_log_evidence_origins_source") })
  }
  func testTwelfthUnknownSchemaCannotCarryUnusableSessionIntoOwnMarker() throws {
    for tool in AgentLogTool.allCases {
      for identity: Any in ["", " ", "\u{a0}", NSNull(), 7] {
        var ordinary = AgentLogState(), replay = AgentLogState()
        let header = try twelfthHeader(tool, identity: "invented-foreign-A", own: false)
        let boundary = try json(tool == .claude ? ["sessionId": identity] : ["payload": ["thread_id": identity]])
        let marker = try json(["type": "system", "cwd": "/invented/" + AgentWindowIdentity.relativeFolder])
        for line in [header, boundary, marker] {
          _ = AgentLogEventParser.parse(Data(line.utf8), byteCount: line.utf8.count, offset: 0,
            observedAt: 300, tool: tool, file: "/invented/log.jsonl", state: &ordinary,
            logsRelativePath: nil, fingerprint: { _ in "invented" })
          var metadata = AgentLogMetadata(); for byte in line.utf8 { metadata.consume(byte) }
          metadata.apply(tool: tool, file: "/invented/log.jsonl", state: &replay, fingerprint: { _ in "invented" })
        }
        XCTAssertNil(ordinary.session); XCTAssertNil(ordinary.ownedSession)
        XCTAssertNil(replay.session); XCTAssertNil(replay.ownedSession)
      }
    }
  }
  func testTwelfthDuplicateIdentityMembersUseOnlyTheFinalBoundary() throws {
    let records: [(AgentLogTool, String, String?)] = [
      (.codex, #"{"type":"event_msg","payload":{"thread_id":"invented-B","thread_id":null}}"#, nil),
      (.codex, #"{"type":"event_msg","payload":{"thread_id":"invented-B"},"payload":{}}"#, "invented-A"),
      (.claude, #"{"type":"system","sessionId":"invented-B","sessionId":null}"#, nil),
      (.claude, #"{"type":"system","sessionId":"","sessionId":"invented-B"}"#, "invented-B")]
    for (tool, boundary, expected) in records {
      var ordinary = AgentLogState(), replay = AgentLogState()
      for line in try [twelfthHeader(tool, identity: "invented-A", own: false), boundary,
        json(["type": "system", "originator": AgentWindowIdentity.codexOriginator])] {
        _ = AgentLogEventParser.parse(Data(line.utf8), byteCount: line.utf8.count, offset: 0,
          observedAt: 300, tool: tool, file: "/invented/log.jsonl", state: &ordinary,
          logsRelativePath: nil, fingerprint: { _ in "invented" })
        var metadata = AgentLogMetadata(); for byte in line.utf8 { metadata.consume(byte) }
        let restored = try JSONDecoder().decode(AgentLogMetadata.self, from: JSONEncoder().encode(metadata))
        restored.apply(tool: tool, file: "/invented/log.jsonl", state: &replay, fingerprint: { _ in "invented" })
      }
      XCTAssertEqual(ordinary.ownedSession?.storedKey, expected)
      XCTAssertEqual(replay.ownedSession?.storedKey, expected)
    }
  }
  func testTwelfthBlankBoundaryCannotEraseEarlierPositiveProofDuringRecovery() throws {
    for tool in AgentLogTool.allCases {
      var ordinary = AgentLogState(), replay = AgentLogState()
      let lines = try [twelfthHeader(tool, identity: "invented-owned-A", own: true),
        twelfthHeader(tool, identity: " ", own: true), json(["type": "system", "originator": AgentWindowIdentity.codexOriginator])]
      for line in lines {
        _ = AgentLogEventParser.parse(Data(line.utf8), byteCount: line.utf8.count, offset: 0,
          observedAt: 300, tool: tool, file: "/invented/log.jsonl", state: &ordinary,
          logsRelativePath: nil, fingerprint: { _ in "invented" })
        var metadata = AgentLogMetadata(); for byte in line.utf8 { metadata.consume(byte) }
        metadata.apply(tool: tool, file: "/invented/log.jsonl", state: &replay, fingerprint: { _ in "invented" })
      }
      XCTAssertNil(ordinary.session); XCTAssertNil(replay.session)
      XCTAssertEqual(ordinary.ownedSession?.storedKey, "invented-owned-A")
      XCTAssertEqual(replay.ownedSession?.storedKey, "invented-owned-A")
    }
  }
  func testTwelfthUnusableBoundariesKeepIndependentHistoricalRefusals() throws {
    var cases = 0
    let values = ["", " ", "\u{a0}", String(repeating: " ", count: 8192), String(repeating: "\u{a0}", count: 4096)]
    for field in ["id", "session_id", "thread_id"] {
      for raw in values {
        for mode in ["fresh", "old", "partial"] {
          let base = root.appendingPathComponent("blank-refusal-\(cases)")
          try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
          let database = base.appendingPathComponent("invented.sqlite")
          var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
          try storage.saveSettings(StorageSettings(), at: 0)
          let historicalThread = field == "thread_id" ? "invented-foreign-A" : raw
          try storage.connection.run("INSERT INTO forgotten_sources VALUES('invented-original',?)",
            [.key("codex:" + historicalThread + ":invented-turn:invented-item")])
          try storage.connection.run("PRAGMA user_version=9")
          storage = nil
          storage = try ActivityStorage(url: database, appDataDirectory: base, databaseScope: .directory(base))
          let url = base.appendingPathComponent("invented.jsonl")
          let header = try twelfthHeader(.codex, identity: "invented-foreign-A", own: false)
          let boundary = try json(["type": field == "thread_id" ? "event_msg" : "session_meta", "payload": [field: raw]])
          let prefix = header + "\n" + boundary + "\n"
          let prompt = try json(["type": "event_msg", "timestamp": stamp(204), "payload": [
            "type": "item_completed", "turn_id": "invented-turn", "item": ["id": "invented-item", "type": "UserMessage",
              "content": [["type": "text", "text": "Invented protected instruction"]]]]])
          try Data((prefix + prompt + "\n").utf8).write(to: url)
          let source = try twelfthSource(url)
          var position: LogPosition?
          if mode != "fresh" {
            var state = AgentLogState(); state.tool = "codex"; state.session = AgentLogIdentityCodec.session("invented-foreign-A")
            if mode == "old" { state.metadataVersion = 0 }
            else {
              state.metadataRecoveryOffset = 1
              var scanner = AgentLogMetadata(); scanner.consume(123)
              state.metadataRecoveryScanner = scanner
            }
            position = LogPosition(path: url.path, device: source.device, inode: source.inode,
              offset: prefix.utf8.count, state: try state.encoded(), seenAt: 299)
          }
          let batch = try AgentLogFiles.read(source, tool: .codex, position: position, at: 300)
          let checkpoint = try AgentLogState.decode(batch.position.state)
          XCTAssertNil(checkpoint.session); XCTAssertNil(checkpoint.ownershipSession); XCTAssertNil(checkpoint.ownedSession)
          XCTAssertNotNil(checkpoint.legacySession)
          try twelfthCommit(batch, storage: storage)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 0, "case \(cases)")
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE role='user'"), 0)
          XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions"), 0)
          storage = nil; cases += 1
        }
      }
    }
    XCTAssertEqual(cases, 45)
    print("Twelfth independent refusal proof: 45 blank/Unicode/long boundary cases, header aliases/explicit threads, fresh/old/partial recovery; zero resurrection or ownership")
  }
  func testTwelfthInvalidJSONOwnMarkersRemainMaskedEventsWithoutOwnership() throws {
    for tool in AgentLogTool.allCases {
      let url = try file(tool)
      let invalid = "{\"type\":\"system\",\"sessionId\":\"invented-foreign\",\"cwd\":\"/invented/" + AgentWindowIdentity.relativeFolder
        + "\",\"originator\":\"" + AgentWindowIdentity.codexOriginator + "\",\"token\":\"invented-secret\",}"
      try write([invalid], to: url)
      let batch = try AgentLogFiles.read(twelfthSource(url), tool: tool, position: nil, at: 300)
      XCTAssertEqual(batch.events.count, 1); XCTAssertEqual(batch.events.first?.parseStatus, "invalidJSON")
      XCTAssertFalse(try XCTUnwrap(batch.events.first).payload.contains("invented-secret"))
      XCTAssertNil(try AgentLogState.decode(batch.position.state).ownedSession)
      try twelfthCommit(batch, storage: store)
    }
    XCTAssertEqual(try eventCount(), 2)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions"), 0)
  }
}
