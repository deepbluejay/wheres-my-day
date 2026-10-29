import Core
import Darwin
import Foundation
import Query
import XCTest

/// The query helper's replies, lease decisions and executable behaviour, compared byte for byte with a
/// golden file recorded from the server before it moved out of Shell. Set QUERY_SERVER_GOLDEN_RECORD=1
/// to write the file again; a difference is a behaviour change, never a fixture to refresh casually.
extension QueryTests {
  private static var golden: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/query-server-golden.txt")
  }

  func testRepliesLeaseDecisionsAndExecutableMatchTheRecordedGolden() throws {
    var lines: [String] = []
    for (name, steps) in Self.replySequences(start: start) {
      var allowed = true
      let server = ActivityQueryServer(queries: query, authorized: { allowed })
      for (index, step) in steps.enumerated() {
        switch step {
        case .authorize(let value): allowed = value
        case .send(let request):
          let reply = server.reply(to: request)
          lines.append("reply \(name)#\(index) " + (reply.map(Self.canonical) ?? "<none>"))
        }
      }
    }
    lines += try leaseDecisions().map { "lease \($0.0) \($0.1)" }
    lines += try executableRuns().map { "executable \($0)" }
    let text = lines.joined(separator: "\n") + "\n"
    if ProcessInfo.processInfo.environment["QUERY_SERVER_GOLDEN_RECORD"] == "1" {
      try Data(text.utf8).write(to: Self.golden)
      return
    }
    let recorded = try String(contentsOf: Self.golden, encoding: .utf8)
    XCTAssertEqual(lines.count, recorded.split(separator: "\n", omittingEmptySubsequences: false).count - 1)
    for (line, expected) in zip(lines, recorded.split(separator: "\n", omittingEmptySubsequences: false)) {
      XCTAssertEqual(line, String(expected))
    }
    XCTAssertEqual(text, recorded)
  }

  private enum Step { case send(Data), authorize(Bool) }

  /// The server already sorts its own keys. A tool answer inside is encoded from Swift dictionaries, whose
  /// order changes with each process's hash seed, so only that inner text is compared with sorted keys.
  private static func canonical(_ reply: Data) -> String {
    guard var object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
      var result = object["result"] as? [String: Any], var content = result["content"] as? [[String: Any]] else {
      return String(decoding: reply, as: UTF8.self)
    }
    for index in content.indices {
      guard let text = content[index]["text"] as? String,
        let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
        let sorted = try? JSONSerialization.data(withJSONObject: answer, options: .sortedKeys) else { continue }
      content[index]["text"] = String(decoding: sorted, as: UTF8.self)
    }
    result["content"] = content; object["result"] = result
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else { return "<unencodable>" }
    return String(decoding: data, as: UTF8.self)
  }

  /// Envelope, identity, authorization, initialization and every tool, each from a fresh server.
  private static func replySequences(start: Int) -> [(String, [Step])] {
    func send(_ text: String) -> Step { .send(Data(text.utf8)) }
    func request(_ method: String, id: String = "1", params: String? = nil) -> Step {
      send("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\"" + (params.map { ",\"params\":\($0)" } ?? "") + "}")
    }
    let initialize = request("initialize", params: #"{"protocolVersion":"2025-11-25"}"#)
    func call(_ params: String) -> Step { request("tools/call", params: params) }
    func tool(_ name: String, _ arguments: String) -> Step { call("{\"name\":\"\(name)\",\"arguments\":\(arguments)}") }
    let ping = #"{"jsonrpc":"2.0","method":"ping","id":1}"#
    let limit = ActivityQueryServer.lineLimit
    var sequences: [(String, [Step])] = []
    sequences.append(("envelope", [send("{"), send("{}"), send("[]"), send("\"x\""), send(""),
      send(#"{"jsonrpc":"1.0","method":"ping","id":1}"#), send(#"{"method":"ping","id":1}"#),
      send(#"{"jsonrpc":"2.0","id":1}"#), send(#"{"jsonrpc":"2.0","method":5,"id":1}"#),
      .send(Data((ping + String(repeating: " ", count: limit - ping.utf8.count)).utf8)),
      .send(Data((ping + String(repeating: " ", count: limit + 1 - ping.utf8.count)).utf8))]))
    sequences.append(("identity", ["null", "true", "false", "{}", "[1]", "\"invented\"", "7", "0", "-1.5", "1e3"].map {
      send("{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":\($0)}")
    } + [send(#"{"jsonrpc":"2.0","method":"ping"}"#), send(#"{"jsonrpc":"2.0","method":"tools/list"}"#)]))
    sequences.append(("authorization", [.authorize(false), request("ping"), send(#"{"jsonrpc":"2.0","method":"ping"}"#),
      send("{"), initialize, .authorize(true), initialize, request("tools/list"), .authorize(false), request("tools/list"),
      tool("day_summary", "{\"at\":\(start)}"), request("unknown/method"), .authorize(true), request("tools/list")]))
    sequences.append(("before-initialize", [request("tools/list"), tool("day_summary", "{\"at\":\(start)}"), request("ping"),
      request("unknown/method"), request("initialize"), request("initialize", params: "[]"),
      request("initialize", params: "{}"), request("initialize", params: #"{"protocolVersion":20251125}"#),
      request("initialize", params: #"{"protocolVersion":true}"#), request("initialize", params: #"{"protocolVersion":null}"#),
      request("initialize", params: #"{"protocolVersion":["2025-11-25"]}"#), initialize, initialize,
      request("initialize", params: #"{"protocolVersion":"2024-11-05"}"#)]))
    for version in ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2099-01-01", ""] {
      sequences.append(("version \(version)", [request("initialize", params: "{\"protocolVersion\":\"\(version)\",\"capabilities\":{}}"),
        request("tools/list")]))
    }
    let range = "\"from\":\(start),\"to\":\(start + 600)"
    sequences.append(("tools", [initialize,
      call("{}"), call("[]"), call(#"{"name":"day_summary"}"#), call(#"{"name":7,"arguments":{}}"#),
      call(#"{"name":"day_summary","arguments":[]}"#), call(#"{"name":"day_summary","arguments":{},"extra":1}"#),
      tool("write", "{}"), tool("sql", "{\"query\":\"invented\"}"), tool("Bash", "{}"),
      call("{\"name\":\"day_summary\",\"arguments\":{\"at\":\(start)},\"_meta\":{\"progressToken\":1}}"),
      tool("day_summary", "{\"at\":\(start)}"), tool("day_summary", "{\"at\":\(start - 1)}"),
      tool("day_summary", "{}"), tool("day_summary", "{\"at\":\(start),\"extra\":1}"),
      tool("day_summary", "{\"at\":true}"), tool("day_summary", "{\"at\":14400.5}"), tool("day_summary", "{\"at\":\"14400\"}"),
      tool("day_summary", "{\"at\":9007199254740991}"), tool("day_summary", "{\"at\":9007199254740992}"),
      tool("what_was_i_doing", "{\"at\":\(start + 60),\"minutes\":1}"), tool("what_was_i_doing", "{\"at\":\(start + 60)}"),
      tool("what_was_i_doing", "{\"at\":\(start + 60),\"minutes\":0}"), tool("what_was_i_doing", "{\"at\":\(start + 60),\"minutes\":-1}"),
      tool("recent_work", "{\(range)}"), tool("recent_work", "{\"from\":\(start + 600),\"to\":\(start)}"),
      tool("recent_work", "{\"from\":\(start)}"), tool("recent_work", "{\(range),\"sql\":\"invented\"}"),
      tool("time_breakdown", "{\(range)}"), tool("time_breakdown", "{\"from\":\(start),\"to\":\(start)}"),
      tool("search_activity", "{\(range),\"query\":\"review plan\"}"), tool("search_activity", "{\(range),\"query\":\"canary\"}"),
      tool("search_activity", "{\(range)}"), tool("search_activity", "{\(range),\"query\":7}"),
      request("resources/list"), request("prompts/get"), request("ping")]))
    return sequences
  }

  /// Each lease condition changed alone from one valid lease, plus the boundaries of size and expiry.
  private func leaseDecisions() throws -> [(String, Bool)] {
    let folder = root.appendingPathComponent("leases")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let database = folder.appendingPathComponent("invented.sqlite").path
    func write(_ name: String, _ bytes: Data, mode: Int = 0o600) throws -> String {
      let url = folder.appendingPathComponent(name)
      try bytes.write(to: url)
      try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
      return url.path
    }
    func lease(token: String = "invented-token", database value: String = database, owner: Int32 = getpid(),
      expires: Int = 2000) throws -> Data {
      try JSONEncoder().encode(QueryRunLease(token: token, database: value, ownerPID: owner, expiresAt: expires))
    }
    let valid = try write("valid.json", lease())
    let base = [QueryToolContract.leaseVariable: valid, QueryToolContract.tokenVariable: "invented-token",
      QueryToolContract.databaseVariable: database]
    func with(_ key: String, _ value: String?) -> [String: String] { var copy = base; copy[key] = value; return copy }
    func leased(_ path: String) -> [String: String] { with(QueryToolContract.leaseVariable, path) }
    let ended = Process()
    ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try ended.run(); ended.waitUntilExit()
    let padded = try lease()
    let symlink = folder.appendingPathComponent("alias.json")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: URL(fileURLWithPath: valid))
    let directory = folder.appendingPathComponent("directory.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let unicode = folder.appendingPathComponent("Fut\u{e9}re.sqlite").path
    var cases: [(String, [String: String], Int)] = [
      ("valid", base, 1000), ("no-lease-variable", with(QueryToolContract.leaseVariable, nil), 1000),
      ("no-token-variable", with(QueryToolContract.tokenVariable, nil), 1000),
      ("no-database-variable", with(QueryToolContract.databaseVariable, nil), 1000),
      ("relative-lease", leased("valid.json"), 1000), ("empty-token", with(QueryToolContract.tokenVariable, ""), 1000),
      ("other-token", with(QueryToolContract.tokenVariable, "different"), 1000),
      ("relative-database", with(QueryToolContract.databaseVariable, "invented.sqlite"), 1000),
      ("dotted-database", with(QueryToolContract.databaseVariable, folder.path + "/missing/../invented.sqlite"), 1000),
      ("other-database", with(QueryToolContract.databaseVariable, folder.appendingPathComponent("other.sqlite").path), 1000),
      ("missing-file", leased(folder.appendingPathComponent("missing.json").path), 1000),
      ("symlink", leased(symlink.path), 1000), ("directory", leased(directory.path), 1000),
      ("mode-0644", leased(try write("0644.json", lease(), mode: 0o644)), 1000),
      ("mode-0400", leased(try write("0400.json", lease(), mode: 0o400)), 1000),
      ("mode-0700", leased(try write("0700.json", lease(), mode: 0o700)), 1000),
      ("size-4096", leased(try write("4096.json", padded + Data(repeating: 0x20, count: 4096 - padded.count))), 1000),
      ("size-4097", leased(try write("4097.json", padded + Data(repeating: 0x20, count: 4097 - padded.count))), 1000),
      ("not-json", leased(try write("text.json", Data("invented".utf8))), 1000),
      ("lease-relative-database", leased(try write("relative-db.json", lease(database: "invented.sqlite"))), 1000),
      ("lease-dotted-database", leased(try write("dotted-db.json", lease(database: folder.path + "/missing/../invented.sqlite"))), 1000),
      ("lease-token-differs", leased(try write("token.json", lease(token: "different"))), 1000),
      ("expiry-minus-one", base, 1999), ("expiry-exact", base, 2000), ("expiry-plus-one", base, 2001),
      ("owner-1", leased(try write("owner-1.json", lease(owner: 1))), 1000),
      ("owner-0", leased(try write("owner-0.json", lease(owner: 0))), 1000),
      ("owner-negative", leased(try write("owner-negative.json", lease(owner: -1))), 1000),
      ("owner-ended", leased(try write("owner-ended.json", lease(owner: ended.processIdentifier))), 1000),
    ]
    var nfd = leased(try write("unicode.json", lease(database: unicode)))
    nfd[QueryToolContract.databaseVariable] = folder.appendingPathComponent("Fute\u{301}re.sqlite").path
    cases.append(("unicode-equivalent", nfd, 1000))
    return cases.map { ($0.0, ActivityQueryServer.leaseIsValid(environment: $0.1, at: $0.2)) }
  }

  /// The executable itself: its start-up guards, a session over the pipe, and revocation mid-run.
  private func executableRuns() throws -> [String] {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let binary = repo.appendingPathComponent(".build/debug/ActivityQueryServer")
    let folder = root.appendingPathComponent("executable")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let database = root.appendingPathComponent("invented.sqlite").path
    let lease = folder.appendingPathComponent("lease.json")
    func writeLease(token: String = "invented-token", database value: String = database) throws {
      let expires = Int(Date().timeIntervalSince1970) + 600
      try JSONEncoder().encode(QueryRunLease(token: token, database: value, ownerPID: getpid(), expiresAt: expires)).write(to: lease)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lease.path)
    }
    let base = ["HOME": folder.path, "PATH": "/usr/bin:/bin", "TZ": "UTC",
      QueryToolContract.leaseVariable: lease.path, QueryToolContract.tokenVariable: "invented-token",
      QueryToolContract.databaseVariable: database, QueryToolContract.appDataVariable: root.path]
    func with(_ key: String, _ value: String?) -> [String: String] { var copy = base; copy[key] = value; return copy }
    let session = [#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
      #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
      #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#,
      "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"day_summary\",\"arguments\":{\"at\":\(start)}}}",
      "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"recent_work\",\"arguments\":{\"from\":\(start),\"to\":\(start + 600)}}}",
      "{", #"{"jsonrpc":"2.0","id":"six","method":"ping"}"#]
    func run(_ name: String, _ environment: [String: String], lines: [String], between: ((Int) throws -> Void)? = nil) throws -> String {
      let process = Process(), input = Pipe(), output = Pipe()
      process.executableURL = binary; process.environment = environment
      process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
      try process.run()
      var replies: [String] = []
      let reader = output.fileHandleForReading
      var pending = Data()
      for (index, line) in lines.enumerated() {
        try between?(index)
        // A helper that refused to start has closed its end; the write fails instead of raising SIGPIPE.
        guard (try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))) != nil else { break }
        // A request without an id gets no line back, so only requests with one wait for it.
        guard line.contains("\"id\"") || line == "{" else { continue }
        while !pending.contains(0x0A) {
          let chunk = reader.availableData
          if chunk.isEmpty { break }
          pending += chunk
        }
        if let end = pending.firstIndex(of: 0x0A) {
          replies.append(Self.canonical(Data(pending[..<end]))); pending = Data(pending[(end + 1)...])
        }
      }
      try? input.fileHandleForWriting.close()
      pending += reader.readDataToEndOfFile()
      process.waitUntilExit()
      replies += pending.split(separator: 0x0A).map { "trailing " + Self.canonical(Data($0)) }
      return "\(name) exit=\(process.terminationStatus) " + replies.joined(separator: " | ")
    }
    let previous = signal(SIGPIPE, SIG_IGN)
    defer { signal(SIGPIPE, previous) }
    try writeLease()
    var runs = [try run("session", base, lines: session)]
    runs.append(try run("no-environment", ["HOME": folder.path, "PATH": "/usr/bin:/bin"], lines: session))
    runs.append(try run("no-app-data", with(QueryToolContract.appDataVariable, nil), lines: session))
    runs.append(try run("empty-app-data", with(QueryToolContract.appDataVariable, ""), lines: session))
    runs.append(try run("other-token", with(QueryToolContract.tokenVariable, "different"), lines: session))
    try writeLease(database: folder.appendingPathComponent("missing.sqlite").path)
    runs.append(try run("missing-database", with(QueryToolContract.databaseVariable, folder.appendingPathComponent("missing.sqlite").path), lines: session))
    try writeLease()
    runs.append(try run("revoked", base, lines: session) { index in
      // Before the notification, so every later line, answered or not, meets the revoked lease.
      if index == 2 { try FileManager.default.removeItem(at: lease) }
    })
    return runs
  }
}
