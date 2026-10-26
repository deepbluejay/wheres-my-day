import Foundation
import Inbound
import SQLite3
import XCTest

@testable import Core
@testable import Storage

/// Invented-data versions of the independent round-12 matrices.
final class AgentLogExactIdentityTests: XCTestCase {
  var base: URL!
  override func setUpWithError() throws {
    base = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"]
        ?? NSTemporaryDirectory()
    ).appendingPathComponent("agent-log-exact-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
  func json(_ v: Any) throws -> String {
    String(
      decoding: try JSONSerialization.data(
        withJSONObject: v, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
  }
  func stamp(_ t: Int) -> String {
    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(t)))
  }
  func rec(_ tool: AgentLogTool, _ field: String, _ value: String, _ t: Int) throws -> String {
    if tool == .claude {
      var d: [String: Any] = [
        "type": "user", "sessionId": "invented-session", "uuid": "invented-item",
        "timestamp": stamp(t), "message": ["role": "user", "content": "Invented instruction"],
      ]
      if field == "attachment.source_uuid" {
        d["type"] = "attachment"
        d["attachment"] = [
          "type": "queued_command", "humanTurn": true, "source_uuid": value,
          "prompt": "Invented instruction",
        ]
      } else {
        d[field] = value
      }
      return try json(d)
    }
    var p: [String: Any] = [
      "type": "item_completed", "thread_id": "invented-thread", "turn_id": "invented-turn",
      "item": [
        "id": "invented-item", "type": "UserMessage",
        "content": [["type": "text", "text": "Invented instruction"]],
      ],
    ]
    var pre = ""
    if field.hasPrefix("header.") {
      p.removeValue(forKey: "thread_id")
      pre =
        try json([
          "type": "session_meta", "timestamp": stamp(t),
          "payload": [String(field.dropFirst(7)): value],
        ]) + "\n"
    } else if field == "item.id" {
      p["item"] = [
        "id": value, "type": "UserMessage",
        "content": [["type": "text", "text": "Invented instruction"]],
      ]
    } else {
      p[field] = value
    }
    return try pre + json(["type": "event_msg", "timestamp": stamp(t), "payload": p])
  }
  func acquire(_ root: URL, _ tool: AgentLogTool, _ n: String, _ text: String) throws
    -> AgentLogBatch
  {
    let url = root.appendingPathComponent(n + ".jsonl").standardizedFileURL
    try Data((text + "\n").utf8).write(to: url)
    let f = try AgentLogFiles.listing([root.path]).files.first {
      $0.path == url.resolvingSymlinksInPath().path
    }!
    var b = try AgentLogFiles.read(f, tool: tool, position: nil, at: 300)
    while b.position.offset < f.size {
      let next = try AgentLogFiles.read(f, tool: tool, position: b.position, at: 300)
      precondition(next.position.offset > b.position.offset || next.ownershipDeferred)
      b.events += next.events
      b.evidence += next.evidence
      b.position = next.position
    }
    return b
  }
  func commit(_ s: ActivityStorage, _ b: AgentLogBatch) throws {
    try s.appendLogEvents(b.events, evidence: b.evidence, position: b.position)
  }

  func testK1ExactReceiptMatrix() throws {
    var cases = 0
    for receipt in ["filesystem", "database"] {
      for role in ["user", "assistant", "tool", "system"] {
        for ownFirst in [false, true] {
          for shape in 0..<2 {
            let r = base.appendingPathComponent("unicode-natural-matrix-" + String(cases))
            try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
            let foreign = shape == 0 ? "invented-caf" + "e\u{301}" : "invented-\u{212b}"
            let own = shape == 0 ? "invented-caf\u{e9}" : "invented-\u{00c5}"
            let keys = ownFirst ? [own, foreign] : [foreign, own]
            let lines = try keys.enumerated().map { i, key in
              try json([
                "type": "event_msg", "timestamp": stamp(200 + i),
                "payload": [
                  "thread_id": key, "turn_id": "invented-turn", "type": "item_completed",
                  "item": [
                    "id": "invented-item-\(i)",
                    "type": role == "user" ? "UserMessage" : "AssistantMessage", "role": role,
                    "content": [["type": "text", "text": "Invented instruction"]],
                  ],
                ],
              ])
            }
            let batch = try acquire(r, .codex, "invented-source", lines.joined(separator: "\n"))
            let db = r.appendingPathComponent("invented.sqlite")
            var s: ActivityStorage! = try ActivityStorage(
              url: db, appDataDirectory: r, databaseScope: .directory(r))
            try s.saveSettings(StorageSettings(), at: 0)
            let registry = AgentLogFiles.ownSources(appDataDirectory: r)
            try commit(
              s,
              acquire(
                r, .codex, "invented-unrelated", rec(.codex, "item.id", "invented-unrelated", 190)))
            if receipt == "filesystem" {
              try registry.registerSession(own, tool: .codex)
            } else {
              let discovery = try json([
                "type": "session_meta", "timestamp": stamp(202),
                "payload": ["id": own, "originator": AgentWindowIdentity.codexOriginator],
              ])
              try commit(s, acquire(r, .codex, "invented-discovery", discovery))
              try FileManager.default.removeItem(
                at: r.appendingPathComponent(AgentLogOwnSources.folderName))
            }
            try commit(s, batch)
            s = nil
            s = try ActivityStorage(url: db, appDataDirectory: r, databaseScope: .directory(r))
            let ownCount = try s.connection.integer(
              "SELECT count(*) FROM agent_log_event_sessions WHERE tool='codex' AND session_id=?",
              [.key(AgentLogEventParser.rawIdentity(own))])
            let count = try s.connection.integer("SELECT count(*) FROM agent_log_events")
            let prompts = try s.connection.integer("SELECT count(*) FROM evidence")
            XCTAssertEqual(ownCount, 0, "case \(cases)")
            XCTAssertEqual(count, 1, "unrelated source survives, case \(cases)")
            XCTAssertEqual(prompts, 1, "unrelated prompt survives, case \(cases)")
            XCTAssertFalse(try registry.containsSession(foreign, tool: .codex))
            s = nil
            cases += 1
          }
        }
      }
    }
    XCTAssertEqual(cases, 32)

  }
  func testK2ExactLineageMatrix() throws {
    var cases = 0
    for shape in 0..<2 {
      for field in ["commandUuid", "source_uuid", "attachment.source_uuid"] {
        for role in ["user", "assistant", "tool", "system"] {
          let r = base.appendingPathComponent("lineage-matrix-\(cases)")
          try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
          let a = shape == 0 ? "invented-cafe\u{301}" : "invented-\u{212b}"
          let c = shape == 0 ? "invented-caf\u{e9}" : "invented-\u{00c5}"
          let db = r.appendingPathComponent("invented.sqlite")
          var s: ActivityStorage! = try ActivityStorage(
            url: db, appDataDirectory: r, databaseScope: .directory(r))
          try s.saveSettings(StorageSettings(), at: 0)
          try commit(s, acquire(r, .claude, "invented-first", rec(.claude, "uuid", a, 200)))
          var link: [String: Any] = [
            "type": role, "timestamp": stamp(202), "sessionId": "invented-session", "uuid": a,
            "message": ["role": role, "content": "Invented instruction"],
          ]
          if field == "attachment.source_uuid" {
            link["attachment"] = ["source_uuid": c]
          } else {
            link[field] = c
          }
          try commit(s, acquire(r, .claude, "invented-linked", json(link)))
          let before = try s.connection.integer("SELECT count(*) FROM evidence")
          let edges = try s.connection.integer("SELECT count(*) FROM agent_prompt_edges")
          let preview = try s.previewDeletion(in: TimeRange(200, 201))
          try s.deleteRecords(in: preview.range, confirmation: preview.confirmation)
          s = nil
          s = try ActivityStorage(url: db, appDataDirectory: r, databaseScope: .directory(r))
          try commit(s, acquire(r, .claude, "invented-future", rec(.claude, "uuid", c, 204)))
          let future = try s.connection.integer(
            "SELECT count(*) FROM agent_log_events WHERE ts=204")
          let evidence = try s.connection.integer("SELECT count(*) FROM evidence")
          XCTAssertEqual([before, edges, future, evidence], [1, 1, 0, 0], "case \(cases)")
          s = nil
          cases += 1
        }
      }
    }
    XCTAssertEqual(cases, 24)

  }
  func testK3BlankNativeMatrix() throws {
    var n = 0
    for (tool, field) in [
      (AgentLogTool.claude, "uuid"), (.claude, "commandUuid"), (.claude, "source_uuid"),
      (.claude, "attachment.source_uuid"), (.codex, "turn_id"), (.codex, "item.id"),
    ] {
      let r = base.appendingPathComponent("native-blank-final-\(n)")
      try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
      let s = try ActivityStorage(
        url: r.appendingPathComponent("invented.sqlite"), appDataDirectory: r,
        databaseScope: .directory(r))
      try s.saveSettings(StorageSettings(), at: 0)
      let values = [String(repeating: " ", count: 4097), String(repeating: "\u{a0}", count: 4097)]
      for (i, value) in values.enumerated() {
        var text = try rec(tool, field, value, 200 + i)
        if tool == .claude && field != "uuid" {
          var row = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
          row["uuid"] = "invented-distinct-item-\(i)"
          text = try json(row)
        }
        try commit(s, acquire(r, tool, "invented-\(i)", text))
      }
      XCTAssertEqual(try s.connection.integer("SELECT count(*) FROM evidence"), 2, "case \(n)")
      n += 1
    }
    XCTAssertEqual(n, 6)

  }
  func testNativeWhitespaceBoundariesStayDistinctAcrossCopiesRestartAndForget() throws {
    let values = [
      "", " ", "\u{a0}", " \t\n\u{a0}",
      String(repeating: " ", count: 4095), String(repeating: " ", count: 4096),
      String(repeating: " ", count: 4097), String(repeating: "\u{a0}", count: 2047) + " ",
      String(repeating: "\u{a0}", count: 2048), String(repeating: "\u{a0}", count: 2048) + " ",
    ]
    for (tool, field) in [
      (AgentLogTool.claude, "uuid"), (.claude, "commandUuid"),
      (.claude, "source_uuid"), (.claude, "attachment.source_uuid"),
      (.codex, "turn_id"), (.codex, "item.id"),
    ] {
      let root = base.appendingPathComponent(tool.rawValue + field)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let database = root.appendingPathComponent("invented.sqlite")
      var storage: ActivityStorage! = try ActivityStorage(
        url: database, appDataDirectory: root, databaseScope: .directory(root))
      try storage.saveSettings(StorageSettings(), at: 0)
      func record(_ value: String, _ index: Int, _ time: Int) throws -> String {
        var object =
          try JSONSerialization.jsonObject(with: Data(rec(tool, field, value, time).utf8))
          as! [String: Any]
        if tool == .claude && field != "uuid" { object["uuid"] = "invented-alias-\(index)" }
        return try json(object)
      }
      for (index, value) in values.enumerated() {
        try commit(
          storage, acquire(root, tool, "invented-first-\(index)", record(value, index, 200 + index))
        )
      }
      XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), values.count)
      storage = nil
      storage = try ActivityStorage(
        url: database, appDataDirectory: root, databaseScope: .directory(root))
      for (index, value) in values.enumerated() {
        try commit(
          storage, acquire(root, tool, "invented-copy-\(index)", record(value, index, 200 + index)))
      }
      XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), values.count)
      let preview = try storage.previewDeletion(in: TimeRange(200, 200 + values.count))
      try storage.deleteRecords(in: preview.range, confirmation: preview.confirmation)
      storage = nil
      storage = try ActivityStorage(
        url: database, appDataDirectory: root, databaseScope: .directory(root))
      for (index, value) in values.enumerated() {
        try commit(
          storage,
          acquire(root, tool, "invented-replay-\(index)", record(value, index, 300 + index)))
      }
      XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 0)
      XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events"), 0)
      storage = nil
    }
  }

  func testDecodedAndStreamedSubjectUseOneKeyAndSessionUnusabilityIsSeparate() throws {
    let values = [
      "invented-cafe\u{301}", "invented-caf\u{e9}", "activityprobe:invented",
      "api_key=invented-value", "{ \"ordinary\": \"invented\" }",
      String(repeating: "x", count: 4095), String(repeating: "x", count: 4096),
      String(repeating: "x", count: 4097), String(repeating: " ", count: 4097),
      String(repeating: "\u{a0}", count: 4097),
    ]
    for value in values {
      let decoded = AgentLogIdentity.decoded(value)
      var streamed = AgentLogIdentity.decoded([UInt8]())
      for byte in value.utf8 { streamed.consume(byte) }
      XCTAssertEqual(streamed.component, decoded.component)
      XCTAssertEqual(streamed.session, decoded.session)
      let key = decoded.component
      XCTAssertEqual(AgentLogIdentityCodec.component(key.storedKey), key)
      let encoded = try JSONEncoder().encode(key)
      XCTAssertEqual(try JSONDecoder().decode(AgentLogNativeComponent.self, from: encoded), key)
    }
    for bytes: [UInt8] in [
      [0xff], [0xc0, 0x80], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xc3],
    ] {
      XCTAssertFalse(AgentLogIdentity.decoded(bytes).isValidUTF8)
    }
    XCTAssertEqual(Set(values.map { AgentLogIdentity.decoded($0).component }).count, values.count)
    XCTAssertEqual(AgentLogIdentity.decoded(String(repeating: " ", count: 4097)).session, .unusable)
    XCTAssertNotEqual(
      AgentLogIdentity.decoded(String(repeating: " ", count: 4097)).component,
      AgentLogIdentity.decoded("").component)
  }

  private func sessionHeader(
    _ tool: AgentLogTool, _ subject: String, _ time: Int, own: Bool = false
  ) throws -> String {
    if tool == .claude {
      var fields: [String: Any] = [
        "type": "system", "sessionId": subject, "timestamp": stamp(time),
      ]
      if own { fields["cwd"] = "/invented/" + AgentWindowIdentity.relativeFolder }
      return try json(fields)
    }
    var payload: [String: Any] = ["id": subject]
    if own { payload["originator"] = AgentWindowIdentity.codexOriginator }
    return try json(["type": "session_meta", "payload": payload, "timestamp": stamp(time)])
  }
  private func inheritedRecord(_ tool: AgentLogTool, _ role: String, _ index: Int) throws -> String
  {
    if tool == .claude {
      return try json([
        "type": role, "timestamp": stamp(200), "uuid": "invented-item-\(index)",
        "message": ["role": role, "content": "Invented inherited instruction"],
      ])
    }
    return try json([
      "type": "event_msg", "timestamp": stamp(200),
      "payload": [
        "type": "item_completed",
        "turn_id": "invented-turn",
        "item": [
          "id": "invented-item-\(index)", "role": role,
          "type": role == "user" ? "UserMessage" : "AssistantMessage",
          "content": [["type": "text", "text": "Invented inherited instruction"]],
        ],
      ],
    ])
  }
  func testInheritedSessionReceiptsRevokeIndependentlyAfterHeaderExpiryAndCheckpointMove() throws {
    var cases = 0
    for tool in AgentLogTool.allCases {
      for role in ["user", "assistant", "tool", "system"] {
        for owned in 0..<2 {
          let root = base.appendingPathComponent("invented-inherited-\(cases)")
          try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
          let database = root.appendingPathComponent("invented.sqlite")
          var storage: ActivityStorage! = try ActivityStorage(
            url: database, appDataDirectory: root, databaseScope: .directory(root))
          try storage.saveSettings(StorageSettings(promptRetentionDays: 1), at: 0)
          let subjects = ["aB7xQ2pL9mR4zT6v", "7QxL2pBm9RzT4vAc"]
          var sources: [AgentLogPhysicalSource] = []
          for (index, subject) in subjects.enumerated() {
            let batch = try acquire(
              root, tool, "invented-source-\(index)",
              [
                sessionHeader(tool, subject, 100),
                inheritedRecord(tool, role, index),
                sessionHeader(tool, "invented-unrelated-\(index)", 300),
              ].joined(separator: "\n"))
            sources.append(AgentLogIdentity.decodedPath(batch.position.path))
            try commit(storage, batch)
          }
          try storage.cleanRetention(at: 86400 + 150)
          XCTAssertEqual(
            try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE ts=100"), 0)
          XCTAssertEqual(
            try storage.connection.integer(
              "SELECT count(DISTINCT session_id) FROM agent_log_events WHERE ts=200"), 1)
          storage = nil
          storage = try ActivityStorage(
            url: database, appDataDirectory: root, databaseScope: .directory(root))
          try commit(
            storage,
            acquire(
              root, tool, "invented-discovery", sessionHeader(tool, subjects[owned], 400, own: true)
            ))
          XCTAssertEqual(
            try storage.connection.integer(
              "SELECT count(*) FROM agent_log_events WHERE source=?", [.key(sources[owned])]), 0)
          XCTAssertEqual(
            try storage.connection.integer(
              "SELECT count(*) FROM agent_log_events WHERE source=? AND ts=200",
              [.key(sources[1 - owned])]), 1)
          XCTAssertEqual(
            try storage.connection.integer("SELECT count(*) FROM evidence"), role == "user" ? 1 : 0)
          XCTAssertFalse(
            try AgentLogFiles.ownSources(appDataDirectory: root).containsSession(
              subjects[1 - owned], tool: tool))
          storage = nil
          storage = try ActivityStorage(
            url: database, appDataDirectory: root, databaseScope: .directory(root))
          XCTAssertEqual(
            try storage.connection.integer(
              "SELECT count(*) FROM agent_log_events WHERE source=?", [.key(sources[owned])]), 0)
          storage = nil
          cases += 1
        }
      }
    }
    XCTAssertEqual(cases, 16)
  }
  func testOwnAdmissionAndRevocationDoNotReadDisplayColumns() throws {
    for tool in AgentLogTool.allCases {
      let root = base.appendingPathComponent("invented-display-guard-" + tool.rawValue)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let storage = try ActivityStorage(
        url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
        databaseScope: .directory(root))
      try storage.saveSettings(StorageSettings(), at: 0)
      let subject = "invented-session@example.invalid"
      try commit(
        storage,
        acquire(
          root, tool, "invented-source",
          [sessionHeader(tool, subject, 100), inheritedRecord(tool, "user", 0)].joined(
            separator: "\n")))
      let batch = try acquire(
        root, tool, "invented-discovery", sessionHeader(tool, subject, 300, own: true))
      let tracker = AgentLogDisplayReadTracker()
      sqlite3_set_authorizer(
        storage.connection.handle,
        { context, action, table, column, _, _ in
          guard action == SQLITE_READ, let table, let column,
            String(cString: table) == "agent_log_events",
            ["session_id", "project", "record_type", "role", "flags", "parse_status"].contains(
              String(cString: column))
          else { return SQLITE_OK }
          Unmanaged<AgentLogDisplayReadTracker>.fromOpaque(context!).takeUnretainedValue().reads +=
            1
          return SQLITE_DENY
        }, Unmanaged.passUnretained(tracker).toOpaque())
      defer { sqlite3_set_authorizer(storage.connection.handle, nil, nil) }
      XCTAssertNoThrow(
        try commit(
          storage,
          acquire(
            root, tool, "invented-dedup-copy",
            [sessionHeader(tool, subject, 100), inheritedRecord(tool, "user", 0)].joined(
              separator: "\n"))))
      XCTAssertNoThrow(try commit(storage, batch))
      XCTAssertEqual(tracker.reads, 0)
    }
  }

  func testByteDelimiterTuplesAndCombiningPrefixAliasesRemainIndependent() throws {
    let first = ("invented-a:\u{301}b", "\u{301}c")
    let second = ("invented-a", "\u{301}b:\u{301}c")
    let keys = [first, second].map {
      AgentLogIdentity.codex(
        thread: AgentLogIdentity.decoded($0.0).component, turn: $0.1, item: "invented-item")
    }
    XCTAssertNotEqual(keys[0], keys[1])
    let storage = try ActivityStorage(
      url: base.appendingPathComponent("invented.sqlite"), appDataDirectory: base,
      databaseScope: .directory(base))
    try storage.saveSettings(StorageSettings(), at: 0)
    func record(_ tuple: (String, String), _ time: Int) throws -> String {
      return try json([
        "type": "event_msg", "timestamp": stamp(time),
        "payload": [
          "type": "item_completed",
          "thread_id": tuple.0, "turn_id": tuple.1,
          "item": [
            "id": "invented-item", "type": "UserMessage",
            "content": [["type": "text", "text": "Invented tuple instruction"]],
          ],
        ],
      ])
    }
    try commit(storage, acquire(base, .codex, "invented-first", record(first, 200)))
    try commit(storage, acquire(base, .codex, "invented-second", record(second, 201)))
    XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 2)
    let preview = try storage.previewDeletion(in: TimeRange(200, 201))
    try storage.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    try commit(storage, acquire(base, .codex, "invented-first-copy", record(first, 203)))
    try commit(storage, acquire(base, .codex, "invented-second-copy", record(second, 204)))
    XCTAssertEqual(
      try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE ts=203"), 0)
    XCTAssertEqual(
      try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE ts=204"), 1)
    let alias = AgentLogIdentity.claude("\u{301}invented-alias")
    let canonical = AgentLogIdentity.claude("\u{301}invented-root")
    XCTAssertTrue(alias.hasPrefix("claude:"))
    XCTAssertTrue(AgentLogEventParser.isNativePromptIdentity(alias.storedKey))
    try storage.appendEvidence([
      EvidenceText(
        ts: 210, kind: .prompt, source: "invented-prefix",
        sourceID: canonical.storedKey, sourceAliases: [alias.storedKey],
        text: "Invented combining prefix")
    ])
    XCTAssertEqual(
      try storage.connection.integer(
        "SELECT count(*) FROM agent_prompt_edges WHERE alias=? AND canonical=?",
        [.key(alias), .key(canonical)]), 1)
    XCTAssertTrue(
      AgentLogIdentity.decoded("activityprobe:\u{301}ordinary").component.hasPrefix(
        "activityprobe:literal-identity:sha256:"))
  }
  func testInheritedReceiptChangesInvalidateDeletionPreview() throws {
    let storage = try ActivityStorage(
      url: base.appendingPathComponent("invented.sqlite"), appDataDirectory: base,
      databaseScope: .directory(base))
    try storage.saveSettings(StorageSettings(), at: 0)
    try commit(
      storage,
      acquire(
        base, .codex, "invented-source",
        [sessionHeader(.codex, "invented-first", 100), inheritedRecord(.codex, "user", 0)].joined(
          separator: "\n")))
    let preview = try storage.previewDeletion(in: TimeRange(200, 201))
    try storage.connection.run(
      "UPDATE agent_log_inherited_sessions SET session_id=? WHERE event_id IN (SELECT id FROM agent_log_events WHERE ts=200)",
      [.key(AgentLogIdentity.decoded("invented-second").session.subject!)])
    XCTAssertThrowsError(
      try storage.deleteRecords(in: preview.range, confirmation: preview.confirmation))
    XCTAssertEqual(
      try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE ts=200"), 1)
  }

}

private final class AgentLogDisplayReadTracker { var reads = 0 }
