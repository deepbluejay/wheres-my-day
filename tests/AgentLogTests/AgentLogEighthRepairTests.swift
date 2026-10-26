@testable import Core
import CryptoKit
import Foundation
@testable import Inbound
@testable import Storage
import XCTest

extension AgentLogTests {
  private func eighthRead(_ url: URL, _ tool: AgentLogTool) throws -> AgentLogBatch {
    let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
    return try AgentLogFiles.read(source, tool: tool, position: store.logPosition(path: url.path), at: 300,
      ownSources: AgentLogFiles.ownSources(appDataDirectory: root))
  }
  private func eighthCommit(_ batch: AgentLogBatch) throws {
    try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
  }
  private func eighthReopen() throws {
    store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
      databaseScope: .directory(root))
  }
  private func eighthRecord(_ tool: AgentLogTool, _ session: String, _ role: String) throws -> String {
    if tool == .claude {
      return try json(["type": role, "sessionId": session, "uuid": session + "-item", "timestamp": stamp(200),
        "message": ["role": role, "content": "Invented eighth instruction"]])
    }
    return try json(["type": "event_msg", "timestamp": stamp(200), "payload": ["thread_id": session,
      "turn_id": "invented-turn", "type": "item_completed", "item": ["id": session + "-item", "role": role,
        "type": role == "user" ? "UserMessage" : "AssistantMessage",
        "content": [["type": "text", "text": "Invented eighth instruction"]]]]])
  }

  func testEighthDifferentialStrictMetadataFixedSeed() throws {
    let paths = [["type"], ["sessionId"], ["cwd"], ["originator"], ["payload", "id"], ["payload", "session_id"],
      ["payload", "thread_id"], ["payload", "cwd"], ["payload", "originator"], ["payload", "item", "originator"],
      ["payload", "source"], ["payload", "thread_source"], ["payload", "parent_thread_id"], ["payload", "origin", "kind"],
      ["payload", "source", "subagent"], ["payload", "thread_source", "subagent"]]
    let identity = Set(["sessionId", "payload.id", "payload.session_id", "payload.thread_id"])
    func lookup(_ object: Any?, _ path: [String]) -> Any? {
      var value = object
      for key in path { value = (value as? [String: Any])?[key] }
      return value
    }
    var seed: UInt64 = 0x8ad50b17
    func random(_ limit: Int) -> Int {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      return Int((seed >> 32) % UInt64(limit))
    }
    let keys = ["type", "sessionId", "cwd", "originator", "payload", "id", "session_id", "thread_id", "item", "origin",
      "kind", "source", "thread_source", "parent_thread_id", "subagent", "payload.thread_id", "payload.id", "payload.cwd",
      "item.originator", "source.subagent", "origin.kind", "payload.item.originator", "unrelated"]
    let strings = ["invented", "", "session_meta", "event_msg", "subagent", "ActivityProbe", "activityprobe_window",
      "/invented/" + AgentWindowIdentity.relativeFolder, "a.b", "quote\"slash\\", "한국어😀", "\u{0000}",
      "activityprobe", "activityprobe:ordinary", AgentLogEventParser.safeIdentity(String(repeating: "x", count: 8192)),
      "activityprobe:literal-identity:sha256:" + String(repeating: "0", count: 64)]
    func quote(_ text: String) -> String {
      String(decoding: try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]), as: UTF8.self)
    }
    func value(_ depth: Int) -> String {
      switch random(depth > 0 ? 6 : 4) {
      case 0: return quote(strings[random(strings.count)])
      case 1: return ["null", "true", "false"][random(3)]
      case 2: return ["0", "-0", "0.5", "-9.001e+3", "123456789", "1E-10"][random(6)]
      case 3: return quote(strings[random(strings.count)])
      case 4: return "[" + (0..<random(5)).map { _ in value(depth-1) }.joined(separator: ",") + "]"
      default:
        return "{" + (0..<random(9)).map { _ in
          var key = quote(keys[random(keys.count)])
          if random(3) == 0 { key = key.replacingOccurrences(of: ".", with: "\\u002e") }
          return key + ":" + value(depth-1)
        }.joined(separator: ",") + "}"
      }
    }
    var records: [Data] = []
    for _ in 0..<1024 {
      let record = "{\"type\":\"event_msg\",\"sessionId\":\"invented-claude\",\"payload\":{\"thread_id\":\"invented-codex\"},"
        + "\"unrelated\":" + value(4) + "," + quote(keys[random(keys.count)]) + ":" + value(3) + "}"
      records.append(Data(record.utf8))
      var broken = Array(record.utf8)
      broken.insert([0, 255, 93, 92, 120][random(5)], at: random(broken.count + 1))
      records.append(Data(broken))
    }
    // Every recognized path gets a literal dotted sibling at every level, in both orders.
    for path in paths where path.count > 1 {
      for depth in 0..<(path.count-1) {
        let suffix = path.dropFirst(depth).joined(separator: ".")
        for order in [false, true] {
          var exact = quote(path.last!) + ":\"invented-real\""
          for key in path.dropFirst(depth).dropLast().reversed() { exact = quote(key) + ":{" + exact + "}" }
          let decoy = quote(suffix).replacingOccurrences(of: ".", with: "\\u002e") + ":\"ActivityProbe\""
          var object = "{" + (order ? exact + "," + decoy : decoy + "," + exact) + "}"
          for key in path.prefix(depth).reversed() { object = "{" + quote(key) + ":" + object + "}" }
          records.append(Data(object.utf8))
        }
      }
    }
    for path in paths {
      var object = quote("invented-escaped")
      for component in path.reversed() {
        let key = String(format: "\"\\u%04x", component.utf8.first!) + component.dropFirst() + "\""
        object = "{" + key + ":" + object + "}"
      }
      records.append(Data(object.utf8))
    }
    let adversarial = [
      #"{"payload":{"thread_id":"old"},"payload":{"thread_id":"new"}}"#,
      #"{"payload":{"thread_id":"old"},"payload":null}"#,
      #"{"payload":{"originator":"ActivityProbe","originator":null}}"#,
      #"{"payload":{"source":{"subagent":true},"source":{}}}"#,
      #"{"type":"session_meta","\u0070ayload":{"\u0069d":"invented-real","item":{"\u006friginator":"ActivityProbe"}}}"#,
      #"{"payload":{"thread_id":"old"},"\u0070ayload":{"thread\u005fid":"new"}}"#,
      #"{"type":"\u005cu0073ession_meta","payload":{"id":"invented-not-header"}}"#,
      #"{"type":"system","cwd":"\u005cu002finvented/Library/Application Support/ActivityProbe/agent-window"}"#,
      #"{"ignored":not-json,"cwd":"/invented/Library/Application Support/ActivityProbe/agent-window"}"#,
      #"{"ignored":[},"sessionId":"invented"}"#,
      #"{"ignored":{"a":[1,2}},"sessionId":"invented"}"#,
      #"{"a":tru}"#, #"{"a":truefalse}"#, #"{"a":Null}"#, #"{"a":01}"#, #"{"a":-}"#,
      #"{"a":1.}"#, #"{"a":1e}"#, #"{"a":1e+}"#, #"{"a":+1}"#, #"{"a":NaN}"#,
      #"{"a":"\x"}"#, #"{"a":"\uZZZZ"}"#, #"{"a":"\ud800"}"#, #"{"a":"\udc00"}"#,
      #"{"a":"\ud800\u0061"}"#, #"{"a":"\ud83d\ude00"}"#, #"{"a":1,}"#, #"{"a":[1,]}"#,
      "{}{}", "{", "[", "true", "123", "1.25e-3", "null", "\"invented\"", "[{},[],null]", "{}\n\t\r ", "\u{feff}{}"
    ]
    records += adversarial.map { Data($0.utf8) }
    for bytes: [UInt8] in [[0xc0,0x80], [0xed,0xa0,0x80], [0xf4,0x90,0x80,0x80], [0xe2,0x82], [0x01]] {
      records.append(Data(Array(#"{"ignored":""#.utf8) + bytes + Array(#""}"#.utf8)))
    }
    // Python supplies an independent strict, last-member oracle. Foundation on this OS
    // accepts trailing commas and keeps first members; canonical fixtures remove those deviations.
    let oracle = Process()
    oracle.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    oracle.arguments = ["-c", """
import base64, json, math, sys
def checked(value):
    if isinstance(value, str): value.encode('utf-8', 'strict')
    elif isinstance(value, list):
        for item in value: checked(item)
    elif isinstance(value, dict):
        for key, item in value.items(): checked(key); checked(item)
    elif isinstance(value, float) and not math.isfinite(value): raise ValueError('nonfinite')
    return value
def decode(encoded):
    try:
        value = json.loads(base64.b64decode(encoded).decode('utf-8', 'strict'),
            parse_constant=lambda _: (_ for _ in ()).throw(ValueError('constant')))
        return json.dumps(checked(value), ensure_ascii=True, allow_nan=False, separators=(',', ':'))
    except (ValueError, UnicodeError): return None
print(json.dumps([decode(item) for item in json.load(sys.stdin)]))
"""]
    let input = root.appendingPathComponent("invented-eighth-oracle-input.json")
    try JSONSerialization.data(withJSONObject: records.map { $0.base64EncodedString() }).write(to: input)
    let inputHandle = try FileHandle(forReadingFrom: input)
    defer { try? inputHandle.close() }
    oracle.standardInput = inputHandle
    let output = Pipe(); oracle.standardOutput = output
    try oracle.run()
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    oracle.waitUntilExit()
    XCTAssertEqual(oracle.terminationStatus, 0)
    let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: outputData) as? [Any])
    var executions = 0
    var foundationValidityDeviations = 0
    var foundationMemberDeviations = 0
    for (index, data) in records.enumerated() {
      let decoded = (canonical[index] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
      let foundation = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      if (foundation != nil) != (decoded != nil) { foundationValidityDeviations += 1 }
      var expected: [String: String] = [:]
      if decoded != nil {
        for path in paths {
          if let string = lookup(decoded, path) as? String {
            let key = path.joined(separator: ".")
            expected[key] = identity.contains(key) ? AgentLogEventParser.rawIdentity(string) : AgentLogEventParser.safeString(string)
          }
        }
      }
      if let decoded, let foundation,
        !NSDictionary(dictionary: ["value": decoded]).isEqual(to: ["value": foundation]) { foundationMemberDeviations += 1 }
      var scanner = AgentLogMetadata()
      for byte in data { scanner.consume(byte) }
      XCTAssertEqual(scanner.complete, decoded != nil, "case \(index)")
      let ordinary = AgentLogJSON.object(data)
      XCTAssertEqual(ordinary != nil, decoded != nil, "ordinary case \(index)")
      if let ordinary, let decoded {
        XCTAssertTrue(NSDictionary(dictionary: ["value": ordinary]).isEqual(to: ["value": decoded]), "ordinary case \(index)")
      }
      XCTAssertEqual(scanner.selectedValues, expected, "case \(index): \(String(decoding: data, as: UTF8.self))")
      let expectedOwn = decoded != nil && ([lookup(decoded, ["originator"]), lookup(decoded, ["payload", "originator"]),
        lookup(decoded, ["payload", "item", "originator"])].compactMap { $0 as? String }.contains {
          ["ActivityProbe", "activityprobe_window"].contains($0)
        } || (lookup(decoded, ["cwd"]) as? String ?? lookup(decoded, ["payload", "cwd"]) as? String)
          .map(AgentWindowIdentity.containsWorkingFolder) == true)
      XCTAssertEqual(scanner.ownMarker, expectedOwn, "case \(index)")
      if decoded != nil && (index < 256 || index >= records.count - adversarial.count - 5) {
        for tool in AgentLogTool.allCases {
          var ordinaryState = AgentLogState(); ordinaryState.session = AgentLogIdentityCodec.session("invented-seed")
          var recoveredState = ordinaryState
          let fingerprint: (String) -> String = { _ in "invented-fingerprint" }
          _ = AgentLogEventParser.parse(data, byteCount: data.count, offset: 0, observedAt: 300, tool: tool,
            file: "invented.jsonl", state: &ordinaryState, logsRelativePath: nil, metadata: scanner, fingerprint: fingerprint)
          scanner.apply(tool: tool, file: "invented.jsonl", state: &recoveredState, fingerprint: fingerprint)
          XCTAssertEqual(recoveredState.session?.storedKey, ordinaryState.session?.storedKey, "session case \(index), \(tool)")
          XCTAssertEqual(recoveredState.project, ordinaryState.project, "project case \(index), \(tool)")
          XCTAssertEqual(recoveredState.ownWorkingFolder == true, ordinaryState.ownWorkingFolder == true, "folder case \(index), \(tool)")
          XCTAssertEqual(recoveredState.ownedSession?.storedKey, ordinaryState.ownedSession?.storedKey, "owned case \(index), \(tool)")
          XCTAssertEqual(recoveredState.metadataRead, ordinaryState.metadataRead, "header case \(index), \(tool)")
          if ordinaryState.ownWorkingFolder != true {
            XCTAssertEqual(recoveredState.ignoredSession, ordinaryState.ignoredSession, "mark case \(index), \(tool)")
          }
        }
      }
      executions += 1
      if data.count <= 180 || index >= records.count - adversarial.count - 5 {
        for split in 0...data.count {
          try autoreleasepool {
            var splitScanner = AgentLogMetadata()
            for byte in data.prefix(split) { splitScanner.consume(byte) }
            if splitScanner.checkpointSafe {
              let saved = try JSONEncoder().encode(splitScanner)
              splitScanner = try JSONDecoder().decode(AgentLogMetadata.self, from: saved)
            }
            for byte in data.dropFirst(split) { splitScanner.consume(byte) }
            XCTAssertEqual(splitScanner.complete, decoded != nil, "case \(index), split \(split)")
            XCTAssertEqual(splitScanner.selectedValues, expected, "case \(index), split \(split)")
            executions += 1
          }
        }
      }
    }
    print("Eighth differential: \(records.count) records, \(executions) executions, seed 0x8ad50b17; Foundation deviations: \(foundationValidityDeviations) validity, \(foundationMemberDeviations) duplicate-member")
  }

  func testEighthSelectedValuesBoundedDigestAndResumableSecrets() throws {
    for size in [0, 1, 55, 56, 63, 64, 65, 4096, 4097, 16384] {
      let text = String(repeating: "a", count: size)
      var digest = AgentLogDigest()
      for byte in text.utf8 { digest.consume(byte) }
      XCTAssertEqual(digest.hex(), SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    for value in [String(repeating: "x", count: 4096), String(repeating: "x", count: 4097), String(repeating: "x", count: 4093) + "😀"] {
      var scanner = AgentLogMetadata()
      for byte in try JSONSerialization.data(withJSONObject: ["sessionId": value]) { scanner.consume(byte) }
      XCTAssertEqual(scanner.explicitSession(tool: .claude)?.storedKey, AgentLogEventParser.safeIdentity(value))
      XCTAssertEqual(scanner.unusableValueCount, 0)
    }
    for field in ["sessionId", "type", "cwd", "originator"] {
      for size in [8192, 1 << 20, 4 << 20] {
        var scanner = AgentLogMetadata()
        for byte in ("{\"" + field + "\":\"").utf8 { scanner.consume(byte) }
        for _ in 0..<size { scanner.consume(120) }
        XCTAssertTrue(scanner.checkpointSafe)
        let saved = try JSONEncoder().encode(scanner)
        XCTAssertLessThan(saved.count, 8192)
        scanner = try JSONDecoder().decode(AgentLogMetadata.self, from: saved)
        for byte in "\"}".utf8 { scanner.consume(byte) }
        XCTAssertTrue(scanner.complete)
        if field == "sessionId" {
          XCTAssertEqual(scanner.explicitSession(tool: .claude)?.storedKey, AgentLogEventParser.safeIdentity(String(repeating: "x", count: size)))
          XCTAssertEqual(scanner.unusableValueCount, 0)
        } else {
          XCTAssertEqual(scanner.unusableValueCount, 1)
          var replay = AgentLogState()
          scanner.apply(tool: .claude, file: "invented.jsonl", state: &replay, fingerprint: { _ in "invented" })
          XCTAssertEqual(try AgentLogState.decode(replay.encoded()).unusableMetadataValues, 1)
        }
      }
    }
    let secret = "sk-proj-" + String(repeating: "s", count: 48)
    let text = String(repeating: "x", count: 4096) + secret + String(repeating: "y", count: 4096)
    let encoded = try JSONSerialization.data(withJSONObject: ["sessionId": text], options: [.sortedKeys])
    for split in [4100, 4120, 4160, 4200, 4250] {
      var scanner = AgentLogMetadata()
      var consumed = 0
      for byte in encoded {
        scanner.consume(byte); consumed += 1
        if consumed >= split && scanner.checkpointSafe && consumed < split + 64 {
          let saved = try JSONEncoder().encode(scanner)
          XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(secret))
          XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(Data(secret.utf8).base64EncodedString()))
          scanner = try JSONDecoder().decode(AgentLogMetadata.self, from: saved)
        }
      }
      XCTAssertEqual(scanner.explicitSession(tool: .claude)?.storedKey, AgentLogEventParser.safeIdentity(text))
    }
    // The decoded identity, rather than its JSON escape spelling, is hashed.
    let escaped = "{\"sessionId\":\"" + String(repeating: "\\u0078", count: 4097) + "\"}"
    var scanner = AgentLogMetadata()
    for byte in escaped.utf8 { scanner.consume(byte) }
    XCTAssertEqual(scanner.explicitSession(tool: .claude)?.storedKey, AgentLogEventParser.safeIdentity(String(repeating: "x", count: 4097)))
    for blank in [String(repeating: " ", count: 8192), String(repeating: "\u{2003}", count: 4097)] {
      var scanner = AgentLogMetadata()
      for byte in try JSONSerialization.data(withJSONObject: ["sessionId": blank]) { scanner.consume(byte) }
      XCTAssertNil(scanner.explicitSession(tool: .claude))
      XCTAssertEqual(AgentLogEventParser.safeIdentity(blank), "")
    }
  }

  func testEighthDottedSubjectsAllRolesReceiptTimingsAndForeignPreservation() throws {
    for tool in AgentLogTool.allCases {
      let foreign = try file(tool, name: "invented-eighth-preserved-\(tool).jsonl")
      try write([eighthRecord(tool, "invented-eighth-foreign-\(tool)", "user")], to: foreign)
      try eighthCommit(eighthRead(foreign, tool))
      let cursor = try XCTUnwrap(store.logPosition(path: foreign.path))
      for role in ["user", "assistant", "tool", "system"] {
        for timing in ["known", "prepared", "database", "late"] {
          let session = "invented-eighth-\(tool)-\(role)-\(timing)"
          let url = try file(tool, name: session + ".jsonl")
          let record = try eighthRecord(tool, session, role)
          let collision = "{\"payload.thread_id\":\"invented-before\"," + record.dropFirst().dropLast()
            + ",\"payload\\u002ethread_id\":\"invented-after\"}"
          try write([collision], to: url)
          let receipts = AgentLogFiles.ownSources(appDataDirectory: root)
          if timing == "known" { try receipts.registerSession(session, tool: tool) }
          let prepared = try eighthRead(url, tool)
          if timing == "late" { try eighthCommit(prepared) }
          try receipts.registerSession(session, tool: tool)
          if ["database", "late"].contains(timing) {
            let own = try file(tool, name: session + "-own.jsonl")
            try write(["{\"type\":\"system\",\"cwd\":\"/invented/" + AgentWindowIdentity.relativeFolder
              + "\",\"sessionId\":\"" + session + "\",\"payload\":{\"thread_id\":\"" + session + "\"}}"], to: own)
            let revocation = try eighthRead(own, tool)
            try store.connection.run("CREATE TRIGGER invented_eighth_abort BEFORE INSERT ON log_positions BEGIN SELECT RAISE(ABORT,'invented failure'); END")
            XCTAssertThrowsError(try eighthCommit(revocation))
            try store.connection.run("DROP TRIGGER invented_eighth_abort")
            try eighthCommit(revocation)
            try FileManager.default.removeItem(at: root.appendingPathComponent(AgentLogOwnSources.folderName))
            try eighthReopen()
          }
          try eighthCommit(prepared)
          XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(url.path))'"), 0)
          XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence WHERE source_id LIKE ?", [.key("%" + session + "%")]), 0)
          XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), 1)
          XCTAssertEqual(try store.logPosition(path: foreign.path)?.offset, cursor.offset)
          XCTAssertEqual(try store.logPosition(path: foreign.path)?.state, cursor.state)
        }
      }
    }
  }

  func testEighthInvalidAndDottedMarkersCannotRevokeForeignCopies() throws {
    let invalid = ["not-json", "01", "1e+", "truefalse", "[}", #""\x""#, #""\ud800""#]
    for tool in AgentLogTool.allCases {
      for role in ["user", "assistant", "tool", "system"] {
        for variant in 0..<(invalid.count + 4) {
          let session = "invented-eighth-marker-\(tool)-\(role)-\(variant)"
          let foreign = try file(tool, name: session + "-foreign.jsonl")
          let own = try file(tool, name: session + "-discovery.jsonl")
          try write([eighthRecord(tool, session, role)], to: foreign)
          try eighthCommit(eighthRead(foreign, tool))
          let cursor = try XCTUnwrap(store.logPosition(path: foreign.path))
          let subject = tool == .claude ? "\"sessionId\":\"\(session)\"" : "\"payload\":{\"thread_id\":\"\(session)\"}"
          let marker = tool == .claude ? "\"cwd\":\"/invented/\(AgentWindowIdentity.relativeFolder)\""
            : "\"originator\":\"ActivityProbe\""
          let bad: String
          if variant < invalid.count { bad = "{\"type\":\"\(role)\",\(subject),\(marker),\"ignored\":\(invalid[variant])}" }
          else if variant < invalid.count + 2 { bad = "{\"type\":\"\(role)\",\(subject),\(marker),\"ignored\":\"invented-invalid-byte\"}" }
          else {
            let key = variant == invalid.count + 2 ? "payload.cwd" : "payload.item.originator"
            let value = variant == invalid.count + 2 ? "/invented/" + AgentWindowIdentity.relativeFolder : "ActivityProbe"
            bad = "{\"type\":\"\(role)\",\(subject),\"\(key)\":\"\(value)\"}"
          }
          try write([bad], to: own)
          if variant == invalid.count || variant == invalid.count + 1 {
            let parts = bad.components(separatedBy: "invented-invalid-byte")
            try (Data(parts[0].utf8) + Data([variant == invalid.count ? 255 : 1]) + Data((parts[1] + "\n").utf8)).write(to: own)
          }
          let batch = try eighthRead(own, tool)
          XCTAssertEqual(batch.events.count, 1)
          if variant < invalid.count { XCTAssertEqual(batch.events.first?.parseStatus, "invalidJSON") }
          if variant == invalid.count { XCTAssertEqual(batch.events.first?.parseStatus, "invalidUTF8") }
          if variant == invalid.count + 1 { XCTAssertEqual(batch.events.first?.parseStatus, "invalidJSON") }
          try store.connection.run("CREATE TRIGGER invented_eighth_marker_abort BEFORE INSERT ON log_positions BEGIN SELECT RAISE(ABORT,'invented failure'); END")
          XCTAssertThrowsError(try eighthCommit(batch))
          try store.connection.run("DROP TRIGGER invented_eighth_marker_abort")
          try eighthCommit(batch)
          try eighthReopen()
          XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), 1)
          XCTAssertEqual(try store.logPosition(path: foreign.path)?.offset, cursor.offset)
          XCTAssertEqual(try store.logPosition(path: foreign.path)?.state, cursor.state)
          XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE tool=? AND session_id=?", [.key(tool.rawValue), .key(session)]), 0)
          let future = try file(tool, name: session + "-future.jsonl")
          try write([eighthRecord(tool, session, role)], to: future)
          let later = try eighthRead(future, tool)
          XCTAssertEqual(later.events.count, 1)
          try eighthCommit(later)
          XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), 1)
        }
      }
    }
  }

  func testEighthCwdRecoveryEveryRoleBothToolsLegacySwitchAndReopen() throws {
    for tool in AgentLogTool.allCases {
      for mode in ["legacy", "current", "switch", "old-validator"] {
        for nested in [false, true] {
          let tag = "invented-eighth-cwd-\(tool)-\(mode)-\(nested)"
          let url = try file(tool, name: tag + ".jsonl")
          let folder = "/invented/" + tag
          try write([json(nested ? ["type": "system", "payload": ["cwd": folder]] : ["type": "system", "cwd": folder])], to: url)
          if mode == "current" { try eighthCommit(eighthRead(url, tool)) }
          else {
            let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
            var state = AgentLogState()
            state.tool = mode == "legacy" ? nil : mode == "old-validator" ? tool.rawValue : (tool == .claude ? "codex" : "claude")
            if mode == "old-validator" {
              state.metadataVersion = 0
              state.session = AgentLogIdentityCodec.session("invented-untrusted")
              state.project = "/invented/untrusted"
              state.ownedSession = AgentLogIdentityCodec.session("invented-untrusted")
              state.ownWorkingFolder = true
            }
            try store.saveLogPosition(LogPosition(path: url.path, device: source.device, inode: source.inode,
              offset: source.size, state: try state.encoded(), seenAt: 200))
          }
          try eighthReopen()
          try append(Data((try eighthRecord(tool, tag, "user") + "\n").utf8), to: url)
          let batch = try eighthRead(url, tool)
          XCTAssertFalse(batch.ownershipDeferred)
          XCTAssertEqual(batch.events.count, 1)
          XCTAssertEqual(batch.evidence.first?.project, folder)
          XCTAssertEqual(try AgentLogState.decode(batch.position.state).project, folder)
          try eighthCommit(batch)
        }
      }
    }
  }

  func testEighthLargeSelectedRecoveryReopensMidIdentityAndMatchesRegistry() throws {
    let secret = "sk-proj-" + String(repeating: "v", count: 48)
    for tool in AgentLogTool.allCases {
      let rawSession = String(repeating: "x", count: AgentLogFiles.batchBytes - 32) + secret
        + String(repeating: "y", count: AgentLogFiles.batchBytes + 128)
      let session = AgentLogEventParser.safeIdentity(rawSession)
      let header = try json(tool == .claude ? ["type": "system", "sessionId": rawSession]
        : ["type": "session_meta", "payload": ["id": rawSession]])
      let url = try file(tool, name: "invented-eighth-large-selected-\(tool).jsonl")
      try write([header], to: url)
      let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
      try store.saveLogPosition(LogPosition(path: url.path, device: source.device, inode: source.inode,
        offset: source.size, state: "{}", seenAt: 200))
      let prompt: String = tool == .claude
        ? try json(["type": "user", "timestamp": stamp(201), "uuid": "invented-large-selected-item", "message": ["content": "Invented recovery instruction"]])
        : try json(["type": "event_msg", "timestamp": stamp(201), "payload": ["type": "item_completed", "turn_id": "invented-turn",
          "item": ["id": "invented-large-selected-item", "type": "UserMessage", "content": [["type": "text", "text": "Invented recovery instruction"]]]]])
      try append(Data((prompt + "\n").utf8), to: url)
      var deferrals = 0
      var final: AgentLogBatch?
      for _ in 0..<5 {
        let batch = try eighthRead(url, tool)
        if batch.ownershipDeferred {
          deferrals += 1
          let state = try AgentLogState.decode(batch.position.state)
          XCTAssertLessThan(batch.position.state.utf8.count, 8192)
          XCTAssertLessThanOrEqual(try XCTUnwrap(state.metadataRecoveryOffset) - (deferrals-1) * AgentLogFiles.batchBytes,
            AgentLogFiles.batchBytes + 64)
          XCTAssertFalse(batch.position.state.contains(secret))
          XCTAssertEqual(batch.position.offset, source.size)
          XCTAssertTrue(batch.events.isEmpty)
        } else { final = batch }
        try eighthCommit(batch)
        try eighthReopen()
        if final != nil { break }
      }
      XCTAssertEqual(deferrals, 2)
      let batch = try XCTUnwrap(final)
      XCTAssertEqual(batch.events.first?.session?.storedKey, session)
      XCTAssertEqual(batch.evidence.count, 1)
      if tool == .codex {
        XCTAssertEqual(batch.evidence.first?.sourceID, AgentLogEventParser.codexIdentity(thread: session, turn: "invented-turn", item: "invented-large-selected-item"))
      }
      let registry = AgentLogFiles.ownSources(appDataDirectory: root)
      try registry.registerSession(rawSession, tool: tool)
      XCTAssertTrue(try registry.containsSession(AgentLogIdentityCodec.session(session), tool: tool))
      XCTAssertTrue(try registry.containsSession(rawSession, tool: tool))
      let known = try file(tool, name: "invented-eighth-large-known-\(tool).jsonl")
      try write([header, prompt], to: known)
      let blocked = try eighthRead(known, tool)
      XCTAssertTrue(blocked.events.isEmpty)
      XCTAssertTrue(blocked.evidence.isEmpty)
    }
  }

  func testEighthLongSessionNativeForgetSurvivesCurrentLegacyAndSwitchRecovery() throws {
    let raw = String(repeating: "x", count: 8192)
    let session = AgentLogEventParser.safeIdentity(raw)
    let header = try json(["type": "session_meta", "payload": ["id": raw]])
    func prompt(_ time: Int) throws -> String {
      try json(["type": "event_msg", "timestamp": stamp(time), "payload": ["type": "item_completed",
        "turn_id": "invented-turn", "item": ["id": "invented-long-forget-item", "type": "UserMessage",
          "content": [["type": "text", "text": "Invented protected instruction"]]]]])
    }
    let seed = try file(.codex, name: "invented-eighth-long-forget-seed.jsonl")
    try write([header, prompt(200)], to: seed)
    try eighthCommit(eighthRead(seed, .codex))
    let native = AgentLogEventParser.codexIdentity(thread: session, turn: "invented-turn", item: "invented-long-forget-item")
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence WHERE source_id=?", [.key(native)]), 1)
    let preview = try store.previewDeletion(in: TimeRange(200, 201))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    for mode in ["current", "legacy", "switch"] {
      let copy = try file(.codex, name: "invented-eighth-long-forget-\(mode).jsonl")
      try write([header], to: copy)
      let source = try XCTUnwrap(AgentLogFiles.listing([copy.deletingLastPathComponent().path]).files.first { $0.path == copy.path })
      var state = AgentLogState()
      state.tool = mode == "legacy" ? nil : mode == "switch" ? "claude" : "codex"
      state.session = AgentLogIdentityCodec.session(session)
      try store.saveLogPosition(LogPosition(path: copy.path, device: source.device, inode: source.inode,
        offset: source.size, state: try state.encoded(), seenAt: 200))
      try append(Data((try prompt(201) + "\n").utf8), to: copy)
      let batch = try eighthRead(copy, .codex)
      XCTAssertEqual(batch.evidence.first?.sourceID, native)
      try eighthCommit(batch)
      try eighthReopen()
      XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 0)
      try append(Data((try prompt(202) + "\n").utf8), to: copy)
      try eighthCommit(eighthRead(copy, .codex))
      XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 0)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence WHERE source_id=?", [.key(native)]), 0)
    }
  }

  func testEighthReaderSelectedAndUnselectedIncreasingCompleteAndUnfinishedValues() throws {
    for tool in AgentLogTool.allCases {
      let url = try file(tool, name: "invented-eighth-oversized-originator-\(tool).jsonl")
      try write([json(["type": "system", "sessionId": "invented-wrapper", "payload": ["thread_id": "invented-wrapper"],
        "originator": String(repeating: " ", count: 8192) + "\"ActivityProbe\""])], to: url)
      let batch = try eighthRead(url, tool)
      XCTAssertEqual(batch.events.count, 1)
      XCTAssertTrue(batch.events.first?.flags.contains("unusableMetadataValues:1") == true)
      XCTAssertNil(try AgentLogState.decode(batch.position.state).ownedSession)
    }
    for field in ["sessionId", "type", "cwd", "padding"] {
      for size in [1 << 20, 4 << 20] {
        let url = try file(.claude, name: "invented-eighth-partial-\(field)-\(size).jsonl")
        try Data(("{\"" + field + "\":\"").utf8).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let block = Data(repeating: 120, count: 65536)
        for _ in 0..<(size / block.count) { try handle.write(contentsOf: block) }
        try handle.close()
        let partial = try eighthRead(url, .claude)
        XCTAssertEqual(partial.position.offset, 0)
        XCTAssertTrue(partial.events.isEmpty)
        XCTAssertTrue(partial.evidence.isEmpty)
        XCTAssertLessThan(partial.position.state.utf8.count, 8192)
        try eighthCommit(partial)
        try eighthReopen()
        try append(Data("\"}\n".utf8), to: url)
        let complete = try eighthRead(url, .claude)
        XCTAssertEqual(complete.events.count, 1)
        XCTAssertGreaterThan(complete.position.offset, size)
        if field == "sessionId" {
          XCTAssertEqual(complete.events.first?.explicitSession?.storedKey, AgentLogEventParser.safeIdentity(String(repeating: "x", count: size)))
        } else if field != "padding" {
          XCTAssertTrue(complete.events.first?.flags.contains("unusableMetadataValues:1") == true)
          XCTAssertEqual(try AgentLogState.decode(complete.position.state).unusableMetadataValues, 1)
        }
        try eighthCommit(complete)
        try eighthReopen()
        XCTAssertTrue(try eighthRead(url, .claude).events.isEmpty)
      }
    }
  }

  func testEighthDigestSpellingCannotAliasALiteralRawSessionAllRolesBothTools() throws {
    for tool in AgentLogTool.allCases {
      for role in ["user", "assistant", "tool", "system"] {
        let raw = String(repeating: "x", count: 8192) + tool.rawValue + role
        let canonical = AgentLogEventParser.rawIdentity(raw)
        let literal = canonical
        let literalKey = AgentLogEventParser.rawIdentity(literal)
        XCTAssertNotEqual(literalKey, canonical)
        XCTAssertNotEqual(AgentLogEventParser.rawIdentity(literalKey), literalKey)
        let registry = AgentLogFiles.ownSources(appDataDirectory: root)
        try registry.registerSession(raw, tool: tool)
        XCTAssertTrue(try registry.containsSession(raw, tool: tool))
        XCTAssertTrue(try registry.containsSession(AgentLogIdentityCodec.session(canonical), tool: tool))
        XCTAssertFalse(try registry.containsSession(literal, tool: tool))
        let tag = "invented-eighth-domain-\(tool)-\(role)"
        let foreign = try file(tool, name: tag + "-foreign.jsonl")
        try write([eighthRecord(tool, literal, role)], to: foreign)
        let batch = try eighthRead(foreign, tool)
        XCTAssertEqual(batch.events.count, 1)
        XCTAssertEqual(batch.events.first?.explicitSession?.storedKey, literalKey)
        try eighthCommit(batch)
        let cursor = try XCTUnwrap(store.logPosition(path: foreign.path))
        let own = try file(tool, name: tag + "-owned.jsonl")
        let header: [String: Any] = tool == .claude
          ? ["type": "system", "sessionId": raw, "cwd": "/invented/" + AgentWindowIdentity.relativeFolder]
          : ["type": "session_meta", "payload": ["id": raw, "originator": "ActivityProbe"]]
        try write([json(header)], to: own)
        let revoked = try eighthRead(own, tool)
        try store.connection.run("CREATE TRIGGER invented_domain_abort BEFORE INSERT ON log_positions BEGIN SELECT RAISE(ABORT,'invented failure'); END")
        XCTAssertThrowsError(try eighthCommit(revoked))
        try store.connection.run("DROP TRIGGER invented_domain_abort")
        try eighthCommit(revoked)
        try eighthReopen()
        XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), 1)
        XCTAssertEqual(try store.logPosition(path: foreign.path)?.state, cursor.state)
        XCTAssertEqual(try store.logPosition(path: foreign.path)?.offset, cursor.offset)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE tool=? AND session_id=?",
          [.key(tool.rawValue), .key(literalKey)]), 0)
        let future = try file(tool, name: tag + "-future.jsonl")
        try write([eighthRecord(tool, literal, role)], to: future)
        XCTAssertEqual(try eighthRead(future, tool).events.count, 1)
        try eighthCommit(eighthRead(future, tool))
        XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), 1)
        try registry.registerSession(literal, tool: tool)
        XCTAssertTrue(try registry.containsSession(literal, tool: tool))
        XCTAssertFalse(try registry.containsSession(literalKey, tool: tool))
        let actualOwnLiteral = try file(tool, name: tag + "-actual-owned-literal.jsonl")
        try write([eighthRecord(tool, literal, role)], to: actualOwnLiteral)
        let excluded = try eighthRead(actualOwnLiteral, tool)
        XCTAssertTrue(excluded.events.isEmpty)
        try eighthCommit(excluded)
        XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), 0)
      }
    }
  }

  func testEighthNativeFilenameFallbackAndDelimiterPrefixesStayInRawDomain() throws {
    func item(_ thread: String? = nil, turn: String = "invented-turn") throws -> Data {
      var payload: [String: Any] = ["type": "item_completed", "turn_id": turn,
        "item": ["id": "invented-item", "type": "UserMessage", "content": [["type": "text", "text": "Invented native instruction"]]]]
      payload["thread_id"] = thread
      return Data(try json(["type": "event_msg", "timestamp": stamp(200), "payload": payload]).utf8)
    }
    func event(_ data: Data, session: String? = nil, file: String = "invented.jsonl") throws -> AgentLogEvent {
      var state = AgentLogState(); state.session = session.map(AgentLogIdentityCodec.session)
      var metadata = AgentLogMetadata()
      for byte in data { metadata.consume(byte) }
      return try XCTUnwrap(AgentLogEventParser.parse(data, byteCount: data.count, offset: 0, observedAt: 300,
        tool: .codex, file: file, state: &state, logsRelativePath: nil, metadata: metadata, fingerprint: { _ in "invented" }))
    }
    let raw = String(repeating: "x", count: 8192)
    let canonical = AgentLogEventParser.rawIdentity(raw)
    let literal = AgentLogEventParser.rawIdentity(canonical)
    let inherited = try event(item(), session: canonical)
    let filename = try event(item(), file: canonical + ".jsonl")
    let inheritedLiteral = try event(item(), session: literal)
    XCTAssertNotEqual(filename.identities, inherited.identities)
    XCTAssertEqual(filename.identities, inheritedLiteral.identities)
    XCTAssertEqual(filename.prompt?.sourceID, filename.identities.first?.storedKey)
    let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    let shifted = try event(item("activityprobe", turn: "long-identity:sha256:" + digest + ":invented-turn"))
    XCTAssertNotEqual(shifted.identities, inherited.identities)
    XCTAssertEqual(shifted.explicitSession?.storedKey, AgentLogEventParser.rawIdentity("activityprobe"))
    let expanding = "[" + Array(repeating: "1e10", count: 700).joined(separator: ",") + "]"
    XCTAssertLessThan(expanding.utf8.count, AgentLogMetadata.tokenLimit)
    XCTAssertGreaterThan(AgentLogEventParser.safeString(expanding).utf8.count, AgentLogMetadata.tokenLimit)
    let bounded = AgentLogEventParser.rawIdentity(expanding)
    XCTAssertLessThanOrEqual(bounded.utf8.count, AgentLogMetadata.tokenLimit)
    XCTAssertEqual(AgentLogEventParser.safeIdentity(bounded), bounded)
    var state = AgentLogState()
    _ = AgentLogParser.parse(try json(["type": "session_meta", "payload": ["id": expanding]]), tool: .codex,
      file: "invented.jsonl", state: &state, fingerprint: { _ in "invented" })
    let before = try event(item(), session: state.session?.storedKey)
    let after = try event(item(), session: AgentLogState.decode(state.encoded()).session?.storedKey)
    XCTAssertEqual(before.identities, after.identities)
    XCTAssertEqual(try event(item(expanding)).identities, after.identities)
  }
}
