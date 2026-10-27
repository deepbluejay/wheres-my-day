import Core
import CryptoKit
import Foundation
@testable import Inbound
@testable import Shell
import XCTest

@testable import Storage

final class InventedProcesses: AgentLogProcessSource {
  var listed: [AgentLogProcess] = []
  var homes: [Int32: String] = [:]
  var denied = Set<Int32>()
  var requested: [(String, Int32)] = []
  var listings = 0
  var listingFails = false
  func processes() throws -> [AgentLogProcess] {
    listings += 1
    if listingFails { throw AgentLogReadError.processUnavailable }
    return listed
  }
  func homeVariable(_ name: String, processID: Int32) throws -> String? {
    requested.append((name, processID))
    if denied.contains(processID) { throw AgentLogReadError.processUnavailable }
    return homes[processID]
  }
}

final class InventedRecorderSources: RecorderClock, InputCountSource, FrontWindowSource,
  SecureInputSource, DisplayAwakeSource, ScreenTextSource
{
  var now = 10000
  func takeInput() -> SourceReading<InputCounts> { .value(InputCounts()) }
  func frontApplication() -> FrontObservation { FrontObservation() }
  func details(for application: FrontObservation) -> FrontObservation { application }
  func secureInput() -> SourceReading<Bool> { .value(false) }
  func keepingDisplayAwake(processID: Int32) -> SourceReading<Bool> { .value(false) }
  func captureText(
    window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    completion: @escaping (SourceReading<String>) -> Void
  ) {
    completion(.value("Invented text"))
  }
}

final class AgentLogTests: XCTestCase {
  var root: URL!
  var store: ActivityStorage!
  var processes: InventedProcesses!
  let all = TimeRange(0, 100000)
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, busyMilliseconds: 0, databaseScope: .directory(root))
    try store.saveFixtureSettings(StorageSettings(subscriptionConnected: true), at: 0)
    processes = InventedProcesses()
  }
  override func tearDownWithError() throws {
    store = nil
    try FileManager.default.removeItem(at: root)
  }
  func file(_ tool: AgentLogTool, home: URL? = nil, name: String = "invented.jsonl") throws -> URL {
    let base = home ?? root.appendingPathComponent(tool.defaultHomeName)
    let folder = base.appendingPathComponent(tool.logsFolder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent(name)
  }
  func reader(_ tool: AgentLogTool) -> AgentLogReader {
    if tool == .claude { return ClaudeAgentLogReader(userHome: root.path, processes: processes) }
    return CodexAgentLogReader(userHome: root.path, processes: processes)
  }
  // Ideal: isolating summary login does not replace the person's two default log homes.
  func testPersonLogHomesStayIndependentOfSummaryHome() throws {
    let appHome = root.appendingPathComponent("app-data/codex")
    try FileManager.default.createDirectory(at: appHome, withIntermediateDirectories: true)
    for tool in AgentLogTool.allCases {
      let personal = try file(tool)
      try Data("Invented session fixture\n".utf8).write(to: personal)
      let paths = try reader(tool).listing().files.map(\.path)
      XCTAssertEqual(paths, [personal.path])
      XCTAssertFalse(paths.contains { $0.hasPrefix(appHome.path + "/") })
    }
  }

  // Ideal: process discovery excludes the app home, including aliases, before any log read.
  func testDiscoveredAppHomeAndAliasesAreNotRead() throws {
    let appHome = root.appendingPathComponent("Library/Application Support/ActivityProbe/codex")
    let personal = try file(.codex)
    try Data("Invented personal session\n".utf8).write(to: personal)
    let own = try file(.codex, home: appHome)
    try Data("Invented app session\n".utf8).write(to: own)
    let alias = root.appendingPathComponent("app-home-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: appHome)
    for path in [appHome.path, appHome.path + "/", alias.path] {
      processes.listed = [AgentLogProcess(pid: 1, tool: .codex)]
      processes.homes = [1: path]
      XCTAssertEqual(try reader(.codex).listing().files.map(\.path), [personal.path])
    }
  }

  func testAppDataOverrideExcludesDiscoveredSummaryHome() throws {
    let appData = root.appendingPathComponent("override")
    let appHome = AppDataPaths.summaryCodexHome(in: appData)
    let own = try file(.codex, home: appHome)
    try Data("Invented app session\n".utf8).write(to: own)
    processes.listed = [AgentLogProcess(pid: 1, tool: .codex)]
    processes.homes = [1: appHome.path]
    let reader = CodexAgentLogReader(userHome: root.path, processes: processes, appDataDirectory: appData)
    XCTAssertTrue(try reader.listing().files.isEmpty)
    let connections = try RecorderConnections(database: appData.appendingPathComponent("invented.sqlite"), appDataDirectory: appData,
      userHome: root.path, processes: processes, fileVault: InventedFileVault(), databaseScope: .directory(root))
    try connections.client.saveFixtureSettings(StorageSettings(subscriptionConnected: true))
    try connections.logTasks[1].scan(at: 10000)
    XCTAssertNil(try connections.client.logPosition(path: own.path))
    XCTAssertEqual(connections.logTasks[1].health.malformedLines, 0)
  }

  // Ideal: a case or Unicode spelling of the app-owned summary home never becomes user evidence. Claude has
  // no app-owned home any more: a Claude folder a running process names is read like the person's own.
  func testEquivalentAppHomeSpellingsAreNotRead() throws {
    let appData = root.appendingPathComponent("Caf\u{e9}App")
    for tool in AgentLogTool.allCases {
      let appHome = appData.appendingPathComponent(tool.rawValue)
      let own = try file(tool, home: appHome)
      try Data("Invented app session\n".utf8).write(to: own)
      let sensitive = try XCTUnwrap(appData.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
      let variant = root.appendingPathComponent(sensitive ? "Cafe\u{301}App" : "cAFE\u{301}aPP")
        .appendingPathComponent(sensitive ? tool.rawValue : tool.rawValue.uppercased())
      processes.listed = [AgentLogProcess(pid: 1, tool: tool)]; processes.homes = [1: variant.path]
      let source = ToolLogFiles(tool: tool, userHome: root.path, processes: processes, appDataDirectory: appData)
      XCTAssertEqual(try source.listing().files.isEmpty, tool == .codex, tool.rawValue)
    }
  }

  // Ideal: overriding the DB never makes the expected app home's logs eligible.
  func testDatabaseOverrideStillExcludesExpectedAppHome() throws {
    let appData = root.appendingPathComponent("expected-app")
    let appHome = AppDataPaths.summaryCodexHome(in: appData)
    let own = try file(.codex, home: appHome)
    let personal = try file(.codex)
    for url in [own, personal] {
      try (meta(.codex) + "\n" + prompt(.codex, id: "invented-request") + "\n")
        .write(to: url, atomically: true, encoding: .utf8)
    }
    let database = root.appendingPathComponent("override-db/invented.sqlite")
    try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
    processes.listed = [AgentLogProcess(pid: 1, tool: .codex)]
    processes.homes = [1: appHome.path]
    let connections = try RecorderConnections(database: database, appDataDirectory: appData,
      userHome: root.path, processes: processes, fileVault: InventedFileVault(), databaseScope: .directory(root))
    try connections.client.saveFixtureSettings(StorageSettings(subscriptionConnected: true))
    try connections.logTasks[1].scan(at: 10000)
    XCTAssertNil(try connections.client.logPosition(path: own.path))
    XCTAssertNotNil(try connections.client.logPosition(path: personal.path))
    XCTAssertEqual(connections.logTasks[1].health.stored, 1)
    XCTAssertEqual(connections.client.securityHealth.backupExclusionFailure?.rawValue,
      "backup_exclusion_skipped_override")
  }

  func stamp(_ time: Int) -> String {
    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(time)))
  }
  func json(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
  }
  func meta(_ tool: AgentLogTool) throws -> String {
    if tool == .claude {
      return try json(["type": "system", "sessionId": "invented-session", "cwd": "/invented/project"])
    }
    return try json([
      "type": "session_meta",
      "payload": [
        "id": "invented-session", "cwd": "/invented/project",
        "thread_source": "user", "originator": "invented-client",
      ],
    ])
  }
  func prompt(_ tool: AgentLogTool, id: String, at time: Int = 100, text: String = "Invented request") throws -> String
  {
    if tool == .claude {
      return try json([
        "type": "user", "timestamp": stamp(time), "uuid": id, "cwd": "/invented/project",
        "origin": ["kind": "human"], "message": ["role": "user", "content": text],
      ])
    }
    return try json([
      "type": "event_msg", "timestamp": stamp(time), "cwd": "/invented/project",
      "payload": [
        "type": "item_completed",
        "turn_id": "invented-turn",
        "item": [
          "type": "UserMessage", "id": id,
          "content": [["type": "text", "text": text]],
        ],
      ],
    ])
  }
  func write(_ lines: [String], to url: URL) throws {
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
  }
  func append(_ bytes: Data, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: bytes)
  }
  func testEachToolsRealFormatKeepsEveryRecordAndProjectsOnlyKnownHumanPrompts() throws {
    for tool in AgentLogTool.allCases {
      let url = try file(tool)
      let own: String
      let result: String
      if tool == .claude {
        own = try json(["type": "assistant", "timestamp": stamp(100), "message": ["content": "Invented answer"]])
        result = try json([
          "type": "user", "timestamp": stamp(100), "uuid": "result",
          "message": ["content": [["type": "tool_result", "content": "Invented output"]]],
        ])
      } else {
        own = try json([
          "type": "event_msg", "timestamp": stamp(100),
          "payload": [
            "type": "item_completed",
            "item": [
              "type": "AgentMessage", "id": "answer", "content": [["type": "Text", "text": "Invented answer"]],
            ],
          ],
        ])
        result = try json(["type": "response_item", "payload": ["role": "user", "content": "Invented context"]])
      }
      try write(
        [meta(tool), prompt(tool, id: "one", text: "/invented-command"), own, result, "malformed", "{}"], to: url)
      let task = AgentLogTask(reader: reader(tool), storage: store)
      try task.scan(at: 200)
      XCTAssertEqual(task.health.stored, 1)
      XCTAssertEqual(task.health.malformedLines, 2)
      XCTAssertEqual(try eventCount("tool='" + tool.rawValue + "'"), 6)
      XCTAssertEqual(try eventCount("tool='" + tool.rawValue + "' AND role='assistant'"), 1)
      let rows = try store.evidence(in: all).filter { $0.sourceID?.hasPrefix(tool.rawValue + ":") == true }
      XCTAssertEqual(rows.map(\.text), ["/invented-command"])
      XCTAssertEqual(rows.first?.project, "/invented/project")
      XCTAssertEqual(rows.first?.ts, 100)
      XCTAssertEqual(rows.first?.kind, .prompt)
      XCTAssertEqual(rows.first?.source, "invented")
      XCTAssertEqual(rows.first?.sourceID, tool == .claude ? "claude:one" : "codex:invented-session:invented-turn:one")
    }
  }
  func testPureParsersAndDeliveredClaudeAttachment() throws {
    var state = AgentLogState()
    let attachment = try json([
      "type": "attachment", "timestamp": stamp(101), "uuid": "delivery",
      "attachment": [
        "type": "queued_command", "source_uuid": "queued", "timestamp": stamp(99),
        "prompt": "Invented queued request", "origin": ["kind": "human"],
      ],
    ])
    guard
      case .prompt(let row) = AgentLogParser.parse(
        attachment, tool: .claude, file: "/invented/log", state: &state, fingerprint: AgentLogFiles.fingerprint)
    else { return XCTFail("delivered human queue instruction must survive") }
    XCTAssertEqual(row.ts, 101)
    XCTAssertEqual(row.sourceID, "claude:queued")
    XCTAssertEqual(row.text, "Invented queued request")
  }
  func testIncrementalAppendPartialLineAndRestartForBothTools() throws {
    for tool in AgentLogTool.allCases {
      let url = try file(tool)
      try write([meta(tool), prompt(tool, id: "one")], to: url)
      let task = AgentLogTask(reader: reader(tool), storage: store)
      try task.scan(at: 200)
      let first = try XCTUnwrap(store.logPosition(path: url.path))
      try task.scan(at: 500)
      XCTAssertEqual(task.health.stored, 1)
      XCTAssertEqual(task.health.refused, 0)
      let next = try prompt(tool, id: "two", at: 101, text: "Invented next request")
      let half = next.utf8.count / 2
      try append(Data(next.utf8.prefix(half)), to: url)
      try task.scan(at: 800)
      XCTAssertEqual(try store.logPosition(path: url.path)?.offset, first.offset)
      XCTAssertEqual(task.health.stored, 1)
      try append(Data(next.utf8.dropFirst(half)) + Data([10]), to: url)
      let restarted = AgentLogTask(reader: reader(tool), storage: store)
      try restarted.scan(at: 1100)
      XCTAssertEqual(restarted.health.stored, 1)
      XCTAssertEqual(try store.logPosition(path: url.path)?.offset, (try Data(contentsOf: url)).count)
    }
    XCTAssertEqual(try store.evidence(in: all).count, 4)
  }
  func testTruncationReplacementAndDeletionForBothTools() throws {
    for tool in AgentLogTool.allCases {
      let url = try file(tool)
      try write([meta(tool), prompt(tool, id: "one"), prompt(tool, id: "two")], to: url)
      let task = AgentLogTask(reader: reader(tool), storage: store)
      try task.scan(at: 200)
      let original = try XCTUnwrap(store.logPosition(path: url.path))
      try write([meta(tool), prompt(tool, id: "one")], to: url)
      try task.scan(at: 500)
      XCTAssertEqual(task.health.stored, 2)
      XCTAssertEqual(task.health.refused, 1)
      let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement.tmp")
      try write([meta(tool), prompt(tool, id: "one"), prompt(tool, id: "three")], to: replacement)
      try FileManager.default.removeItem(at: url)
      try FileManager.default.moveItem(at: replacement, to: url)
      try task.scan(at: 800)
      XCTAssertNotEqual(try store.logPosition(path: url.path)?.inode, original.inode)
      XCTAssertEqual(task.health.stored, 3)
      XCTAssertEqual(task.health.refused, 2)
      let listed = try XCTUnwrap(reader(tool).files().first)
      try FileManager.default.removeItem(at: url)
      XCTAssertThrowsError(try reader(tool).read(listed, position: nil, at: 900))
      try task.scan(at: 1100)
      XCTAssertEqual(task.health.lastSuccessTime, 1100)
      XCTAssertEqual(task.health.stored, 3)
    }
  }
  func testMultipleHomesAliasesAndProcessesThatDisappearOrDenyInspection() throws {
    for tool in AgentLogTool.allCases {
      let custom = root.appendingPathComponent("custom-" + tool.rawValue)
      let alias = root.appendingPathComponent("alias-" + tool.rawValue)
      let one = try file(tool)
      let two = try file(tool, home: custom)
      try write([prompt(tool, id: "one")], to: one)
      try write([prompt(tool, id: "two")], to: two)
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: custom)
      processes.listed = [1, 2, 3, 4].map { AgentLogProcess(pid: $0, tool: tool) }
      processes.homes = [1: custom.path, 2: alias.path]
      processes.denied = [3, 4]
      let task = AgentLogTask(reader: reader(tool), storage: store)
      try task.scan(at: 200)
      XCTAssertEqual(task.health.stored, 2)
      XCTAssertEqual(task.health.refused, 0)
      XCTAssertEqual(processes.requested.suffix(4).map { $0.0 }, Array(repeating: tool.homeVariable, count: 4))
    }
  }
  func testDisconnectedAccountStillCollectsLocalLogs() throws {
    let url = try file(.claude)
    try write([prompt(.claude, id: "one")], to: url)
    try store.saveFixtureSettings(StorageSettings(), at: 0)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(processes.listings, 1)
    XCTAssertEqual(task.health.stored, 1)
    XCTAssertNotNil(try store.logPosition(path: url.path))
    XCTAssertEqual(task.health.lastSuccessTime, 200)
    XCTAssertEqual(try eventCount(), 1)
  }
  func testPauseOffAndDeletedRangesAdvancePositionAndCountRefused() throws {
    for tool in AgentLogTool.allCases {
      let url = try file(tool)
      try store.saveFixtureSettings(StorageSettings(pausedUntil: 120, subscriptionConnected: true), at: 100)
      try store.saveFixtureSettings(StorageSettings(recordingEnabled: false, subscriptionConnected: true), at: 130)
      try store.saveFixtureSettings(StorageSettings(subscriptionConnected: true), at: 150)
      try write(
        [
          prompt(tool, id: "before", at: 99), prompt(tool, id: "paused", at: 110),
          prompt(tool, id: "resumed", at: 125), prompt(tool, id: "off", at: 140),
          prompt(tool, id: "deleted", at: 160), prompt(tool, id: "after", at: 170),
        ], to: url)
      let preview = try store.previewDeletion(in: TimeRange(160, 161))
      _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
      let task = AgentLogTask(reader: reader(tool), storage: store)
      try task.scan(at: 200)
      XCTAssertEqual(task.health.stored, 3)
      XCTAssertEqual(task.health.refused, 3)
      XCTAssertEqual(try store.logPosition(path: url.path)?.offset, (try Data(contentsOf: url)).count)
      try task.scan(at: 500)
      XCTAssertEqual(task.health.refused, 3)
    }
  }
  func testVeryLongLinesAndInvalidUTF8ForBothTools() throws {
    for tool in AgentLogTool.allCases {
      let url = try file(tool)
      let longText = String(repeating: "Invented words ", count: 90000)
      try write([prompt(tool, id: "long", text: longText)], to: url)
      try append(Data([0xff, 0xfe, 10]), to: url)
      try append(Data(repeating: 120, count: AgentLogFiles.longestLineBytes + 1) + Data([10]), to: url)
      try append(Data((try prompt(tool, id: "after", at: 101) + "\n").utf8), to: url)
      let task = AgentLogTask(reader: reader(tool), storage: store)
      try task.scan(at: 200)
      XCTAssertEqual(task.health.stored, 2)
      XCTAssertEqual(task.health.malformedLines, 2)
      let rows = try store.evidence(in: all).filter { $0.sourceID?.hasPrefix(tool.rawValue + ":") == true }
      XCTAssertEqual(rows.first?.text, longText)
    }
  }
  func testSecretPromptMaskedInMainFileAndWAL() throws {
    let url = try file(.codex)
    let secret = "INVENTED_SECRET_PROMPT_VALUE_ABCXYZ"
    try write([prompt(.codex, id: "secret", text: "api_key=" + secret)], to: url)
    let task = AgentLogTask(reader: reader(.codex), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(task.health.stored, 1)
    XCTAssertFalse(try XCTUnwrap(store.evidence(in: all).first).text.contains(secret))
    for suffix in ["", "-wal"] {
      let bytes = (try? Data(contentsOf: root.appendingPathComponent("invented.sqlite" + suffix))) ?? Data()
      XCTAssertNil(bytes.range(of: Data(secret.utf8)))
    }
  }
  func testBusyBatchIsAtomicAndRetryStoresExactlyOnce() throws {
    let url = try file(.claude)
    try write([prompt(.claude, id: "one"), prompt(.claude, id: "two")], to: url)
    let blocker = try SQLiteConnection(url: root.appendingPathComponent("invented.sqlite"), scope: .directory(root), busyMilliseconds: 0)
    try blocker.run("BEGIN IMMEDIATE")
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    XCTAssertThrowsError(try task.scan(at: 200))
    XCTAssertNil(try store.logPosition(path: url.path))
    XCTAssertEqual(try store.evidence(in: all), [])
    XCTAssertEqual(task.health.lastErrorKind, .busy)
    try blocker.run("ROLLBACK")
    try task.scan(at: 500)
    try task.scan(at: 800)
    XCTAssertEqual(task.health.stored, 2)
    XCTAssertEqual(task.health.refused, 0)
    XCTAssertEqual(task.health.failures, 1)
    XCTAssertEqual(task.health.lastSuccessTime, 800)
    XCTAssertNil(task.health.lastErrorKind)
  }
  func testOneVariableExtractionNeverReturnsNeighboursOrArguments() throws {
    let environment = Data(
      "API_KEY=INVENTED_SECRET_NEIGHBOUR\0CODEX_HOME=/invented/home\0TOKEN=INVENTED_OTHER_SECRET\0".utf8)
    XCTAssertEqual(environment.withUnsafeBytes { NamedProcessVariable.value("CODEX_HOME", in: $0) }, "/invented/home")
    XCTAssertNil(environment.withUnsafeBytes { NamedProcessVariable.value("CLAUDE_CONFIG_DIR", in: $0) })
    var argc: Int32 = 2
    var block = withUnsafeBytes(of: &argc) { Data($0) }
    block.append(Data("/invented/codex\0\0codex\0CODEX_HOME=/invented/argument\0".utf8))
    block.append(environment)
    XCTAssertEqual(
      block.withUnsafeBytes {
        NamedProcessVariable.value("CODEX_HOME", inProcessArguments: $0)
      }, "/invented/home")
    XCTAssertNil(
      Data([1, 2]).withUnsafeBytes {
        NamedProcessVariable.value("CODEX_HOME", inProcessArguments: $0)
      })
  }
  func testMissingIDsKeepNewOccurrencesAfterOffsetShift() throws {
    for tool in AgentLogTool.allCases {
      let url = try file(tool)
      var raw = try JSONSerialization.jsonObject(with: Data(prompt(tool, id: "remove").utf8)) as! [String: Any]
      if tool == .claude {
        raw.removeValue(forKey: "uuid")
      } else {
        var payload = raw["payload"] as! [String: Any]
        var item = payload["item"] as! [String: Any]
        item.removeValue(forKey: "id")
        payload["item"] = item
        raw["payload"] = payload
      }
      let line = try json(raw)
      try write([meta(tool), line, prompt(tool, id: "other")], to: url)
      let task = AgentLogTask(reader: reader(tool), storage: store)
      try task.scan(at: 200)
      try write([line], to: url)
      try task.scan(at: 500)
      XCTAssertEqual(task.health.stored, 3)
      XCTAssertEqual(task.health.refused, 0)
    }
  }
  func testReplacedCaptureCompletesItsLossImmediatelyAndOnlyOnce() throws {
    let flights = ScreenTextFlights()
    var first: [SourceAbsence] = []
    var second: [SourceAbsence] = []
    let original = try XCTUnwrap(
      flights.begin(at: 0) {
        if case .absent(let reason) = $0 { first.append(reason) }
      })
    XCTAssertNil(
      flights.begin(at: 30) {
        if case .absent(let reason) = $0 { second.append(reason) }
      })
    XCTAssertEqual(second, [.busy])
    let replacement = try XCTUnwrap(
      flights.begin(at: 30.001) {
        if case .absent(let reason) = $0 { second.append(reason) }
      })
    XCTAssertEqual(first, [.superseded])
    flights.finish(original, result: .value("Invented stale result"))
    XCTAssertEqual(first, [.superseded])
    flights.finish(replacement, result: .absent(.permission))
    XCTAssertEqual(second, [.busy, .permission])
    XCTAssertNotNil(flights.begin(at: 30.002) { _ in })
  }
  func testConvertedCursorRecoversSchemaMetadataWithoutKeepingUnscopedIdentity() throws {
    let url = try file(.codex)
    let header = try meta(.codex)
    try write([header, prompt(.codex, id: "one")], to: url)
    let listed = try XCTUnwrap(reader(.codex).files().first)
    let state = try json([
      "folder": "/invented/legacy-project", "threadID": "invented-legacy-thread",
      "subagent": true, "continuedFrom": "invented-parent", "interactive": false,
    ])
    try store.saveLogPosition(
      LogPosition(
        path: listed.path, device: listed.device, inode: listed.inode, offset: header.utf8.count + 1,
        state: state, seenAt: 100))
    let task = AgentLogTask(reader: reader(.codex), storage: store)
    try task.scan(at: 200)
    let row = try XCTUnwrap(store.evidence(in: all).first)
    XCTAssertEqual(row.project, "/invented/project")
    XCTAssertEqual(row.sourceID, "codex:invented-session:invented-turn:one")
    let checkpoint = try XCTUnwrap(store.logPosition(path: url.path))
    XCTAssertEqual(checkpoint.offset, listed.size)
    XCTAssertEqual(try AgentLogState.decode(checkpoint.state).session?.storedKey, "invented-session")
    XCTAssertFalse(checkpoint.state.contains("subagent"))
    XCTAssertFalse(checkpoint.state.contains("continuedFrom"))
  }
  func testImportedPauseSnapshotGatesHistoricalPrompts() throws {
    let adopted = try ActivityStorage(url: root.appendingPathComponent("imported.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    let privacy = root.appendingPathComponent("invented-privacy.json")
    let general = root.appendingPathComponent("invented-general.json")
    try Data(json(["pausedUntil": 120, "apps": []]).utf8).write(to: privacy)
    try Data("{}".utf8).write(to: general)
    XCTAssertTrue(try adopted.importOldSettings(privacyFile: privacy, generalFile: general))
    var settings = try adopted.settings()
    settings.subscriptionConnected = true
    try adopted.saveFixtureSettings(settings, at: 200)
    let url = try file(.claude)
    try write([prompt(.claude, id: "paused", at: 90), prompt(.claude, id: "resumed", at: 120)], to: url)
    let task = AgentLogTask(reader: reader(.claude), storage: adopted)
    try task.scan(at: 300)
    XCTAssertEqual(task.health.stored, 1)
    XCTAssertEqual(task.health.refused, 1)
  }
  func testExistingSettingsSeedHistoryAndPrivacySurvivesDeletionAndRetention() throws {
    let database = root.appendingPathComponent("adoption.sqlite")
    do {
      let previous = try ActivityStorage(url: database, appDataDirectory: database.deletingLastPathComponent(), databaseScope: .directory(root))
      try previous.saveFixtureSettings(StorageSettings(pausedUntil: 120, subscriptionConnected: true), at: 100)
      try previous.connection.run("DROP TABLE log_recording_history")
      try makeMainLogOrigin(previous)
    }
    let migrated = try ActivityStorage(url: database, appDataDirectory: database.deletingLastPathComponent(), databaseScope: .directory(root))
    let history = try migrated.logRecordingHistory()
    XCTAssertEqual(history, [LogRecordingState(since: Int.min, enabled: true, pausedUntil: 120)])
    let url = try file(.claude)
    try write([prompt(.claude, id: "paused", at: 110), prompt(.claude, id: "resumed", at: 120)], to: url)
    let task = AgentLogTask(reader: reader(.claude), storage: migrated)
    try task.scan(at: 200)
    XCTAssertEqual(task.health.stored, 1)
    XCTAssertEqual(task.health.refused, 1)
    let preview = try migrated.previewDeletion(in: TimeRange(120, 121))
    _ = try migrated.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    _ = try migrated.cleanRetention(at: 100000)
    XCTAssertEqual(try migrated.logRecordingHistory(), history)
    XCTAssertTrue(try migrated.settings().subscriptionConnected)
  }
  func testApplicationExclusionsDoNotApplyToLogsAndPositionFailureRollsBackEvidence() throws {
    try store.saveFixtureSettings(StorageSettings(excludedApps: ["claude", "codex"], subscriptionConnected: true), at: 0)
    let url = try file(.claude)
    try write([prompt(.claude, id: "one")], to: url)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(task.health.stored, 1)
    let row = EvidenceText(ts: 101, kind: .prompt, source: "invented-file", sourceID: "new", text: "Invented text")
    let bad = LogPosition(path: "invented-path", device: 1, inode: 2, offset: -1, seenAt: 200)
    XCTAssertThrowsError(try store.appendLogBatch([row], position: bad))
    XCTAssertNil(try store.logPosition(path: bad.path))
    XCTAssertEqual(try store.evidence(in: all).count, 1)
  }
  func testShellConnectionsAndReaderTasksUseSeparateClient() throws {
    let connections = try RecorderConnections(
      database: root.appendingPathComponent("other.sqlite"), appDataDirectory: root, userHome: root.path, processes: processes, fileVault: InventedFileVault(), databaseScope: .directory(root))
    XCTAssertFalse(connections.recorder === connections.client)
    for task in connections.logTasks {
      XCTAssertTrue((task.storage as AnyObject) === connections.client)
    }
    XCTAssertEqual(connections.maintenanceTasks.map(\.name), ["claude-logs", "codex-logs", "git-history", "security-health"])
    // Holding the background object's in-process lock must not block recorder settings reads.
    let held = expectation(description: "client lock held")
    let release = DispatchSemaphore(value: 0)
    let ended = expectation(description: "client lock released")
    // An invented worker holds only the client lock off the main thread.
    DispatchQueue.global().async {
      connections.client.lock.lock()
      held.fulfill()
      _ = release.wait(timeout: .now() + 5)
      connections.client.lock.unlock()
      ended.fulfill()
    }
    wait(for: [held], timeout: 5)
    let start = Date()
    _ = try connections.recorder.settings()
    let sources = InventedRecorderSources()
    let loop = connections.makeLoop(
      clock: sources, input: sources, front: sources, secure: sources,
      awake: sources, screen: sources, ownBundleID: "invented.own")
    XCTAssertTrue((loop.maintenanceStorage as AnyObject) === connections.client)
    loop.tick()
    loop.stop()
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    release.signal()
    wait(for: [ended], timeout: 5)
  }
}
