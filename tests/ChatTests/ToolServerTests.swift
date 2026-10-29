import Core
import Darwin
import Foundation
import Query
import XCTest

extension QueryTests {
  func testUnidentifiableRequestsOmitTheResponseID() throws {
    let server = ActivityQueryServer(queries: query, authorized: { false })
    for text in ["{", "{}", "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":null}",
      "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":true}",
      "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}"] {
      let response = try XCTUnwrap(server.reply(to: Data(text.utf8)))
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
      XCTAssertNil(object["id"]); XCTAssertNotNil(object["error"])
    }
    for id: Any in ["invented", 3] {
      let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "ping", "id": id])
      let response = try XCTUnwrap(server.reply(to: request))
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
      XCTAssertEqual(String(describing: object["id"]!), String(describing: id))
    }
  }
  private func initialize(_ server: ActivityQueryServer, params: [String: Any]) throws -> [String: Any] {
    let bytes = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1,
      "method": "initialize", "params": params])
    return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(server.reply(to: bytes))) as? [String: Any])
  }

  func testServerEchoesEachSupportedProtocolVersion() throws {
    for version in ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"] {
      let server = ActivityQueryServer(queries: query, authorized: { true })
      let reply = try initialize(server, params: ["protocolVersion": version])
      XCTAssertNil(reply["error"], version)
      let result = try XCTUnwrap(reply["result"] as? [String: Any])
      XCTAssertEqual(result["protocolVersion"] as? String, version)
      XCTAssertEqual(((result["capabilities"] as? [String: Any])?["tools"] as? [String: Bool])?["listChanged"], false)
      XCTAssertEqual((result["serverInfo"] as? [String: String])?["name"], "ActivityProbe")
    }
  }

  func testUnknownProtocolVersionNegotiatesLatestSupportedVersion() throws {
    for version in ["2099-01-01", "", "invented-version"] {
      let server = ActivityQueryServer(queries: query, authorized: { true })
      let reply = try initialize(server, params: ["protocolVersion": version])
      XCTAssertNil(reply["error"], version)
      XCTAssertEqual((reply["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
    }
  }

  func testInvalidProtocolVersionDoesNotInitializeServer() throws {
    let server = ActivityQueryServer(queries: query, authorized: { true })
    let invalid: [[String: Any]] = [[:], ["protocolVersion": 20251125], ["protocolVersion": true],
      ["protocolVersion": NSNull()], ["protocolVersion": ["2025-11-25"]], ["protocolVersion": [:]]]
    for params in invalid {
      let reply = try initialize(server, params: params)
      XCTAssertNil(reply["result"])
      let error = try XCTUnwrap(reply["error"] as? [String: Any])
      XCTAssertEqual(error["code"] as? Int, -32600)
      XCTAssertEqual(error["message"] as? String, "invalid_request")
    }
    XCTAssertNotNil(try initialize(server, params: ["protocolVersion": "2025-11-25"])["result"])
  }

  func testServerOnlyInitializesOnceIncludingAfterVersionFallback() throws {
    for version in ["2025-11-25", "2099-01-01"] {
      let server = ActivityQueryServer(queries: query, authorized: { true })
      XCTAssertNotNil(try initialize(server, params: ["protocolVersion": version])["result"])
      let reply = try initialize(server, params: ["protocolVersion": "2025-11-25"])
      XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32600)
      XCTAssertNil(reply["result"])
    }
  }

  func testExecutableRepliesBeforeTheNextRequestAndBeforeEOF() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let lease = root.appendingPathComponent("interactive-lease.json")
    let database = root.appendingPathComponent("invented.sqlite")
    let value = QueryRunLease(token: "invented-interactive-token", database: database.path, ownerPID: getpid(),
      expiresAt: Int(Date().timeIntervalSince1970) + 60)
    try JSONEncoder().encode(value).write(to: lease)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lease.path)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [repo.appendingPathComponent("tests/ChatTests/Fixtures/interactive_pipe.py").path,
      repo.appendingPathComponent(".build/debug/ActivityQueryServer").path]
    process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1",
      QueryToolContract.leaseVariable: lease.path, QueryToolContract.tokenVariable: value.token,
      QueryToolContract.databaseVariable: database.path, QueryToolContract.appDataVariable: root.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }

  func testLeaseRequiresThisLiveRunAndRegularPrivateFile() throws {
    let path = root.appendingPathComponent("lease.json")
    let value = QueryRunLease(token: "invented-token", database: root.appendingPathComponent("invented.sqlite").path,
      ownerPID: getpid(), expiresAt: 2000)
    try JSONEncoder().encode(value).write(to: path)
    let environment = [QueryToolContract.leaseVariable: path.path, QueryToolContract.tokenVariable: "invented-token",
      QueryToolContract.databaseVariable: value.database]
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    XCTAssertTrue(ActivityQueryServer.leaseIsValid(environment: environment, at: 1000))
    let sensitive = try XCTUnwrap(root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
    var variant = environment
    variant[QueryToolContract.databaseVariable] = root.appendingPathComponent("INVENTED.SQLITE").path
    XCTAssertEqual(ActivityQueryServer.leaseIsValid(environment: variant, at: 1000), !sensitive)
    variant[QueryToolContract.databaseVariable] = root.appendingPathComponent("different.sqlite").path
    XCTAssertFalse(ActivityQueryServer.leaseIsValid(environment: variant, at: 1000))
    variant[QueryToolContract.databaseVariable] = root.path + "/missing/../invented.sqlite"
    XCTAssertFalse(ActivityQueryServer.leaseIsValid(environment: variant, at: 1000))
    XCTAssertFalse(ActivityQueryServer.leaseIsValid(environment: environment, at: 2000))
    XCTAssertFalse(ActivityQueryServer.leaseIsValid(environment: [:], at: 1000))
    var wrong = environment; wrong[QueryToolContract.tokenVariable] = "different"
    XCTAssertFalse(ActivityQueryServer.leaseIsValid(environment: wrong, at: 1000))
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
    XCTAssertFalse(ActivityQueryServer.leaseIsValid(environment: environment, at: 1000))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    let alias = root.appendingPathComponent("alias.json")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: path)
    wrong = environment; wrong[QueryToolContract.leaseVariable] = alias.path
    XCTAssertFalse(ActivityQueryServer.leaseIsValid(environment: wrong, at: 1000))
    try FileManager.default.removeItem(at: path)
    XCTAssertFalse(ActivityQueryServer.leaseIsValid(environment: environment, at: 1000))
  }
  func testLeaseAcceptsEquivalentUnicodeDatabaseBeforeAndAfterCreation() throws {
    let path = root.appendingPathComponent("unicode-lease.json")
    let database = root.appendingPathComponent("Fut\u{e9}re.sqlite")
    let lease = QueryRunLease(token: "invented-token", database: database.path, ownerPID: getpid(), expiresAt: 2000)
    try JSONEncoder().encode(lease).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    let environment = [QueryToolContract.leaseVariable: path.path, QueryToolContract.tokenVariable: lease.token,
      QueryToolContract.databaseVariable: root.appendingPathComponent("Fute\u{301}re.sqlite").path]
    XCTAssertTrue(ActivityQueryServer.leaseIsValid(environment: environment, at: 1000))
    try Data().write(to: database)
    XCTAssertTrue(ActivityQueryServer.leaseIsValid(environment: environment, at: 1000))
  }
  // Ideal: only five read-only tools, with no resources, deletion, raw SQL or shell.
  func testRunServerContractAndRevocation() throws {
    var allowed = true
    let server = ActivityQueryServer(queries: query, authorized: { allowed })
    func request(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
      let bytes = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
      return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(server.reply(to: bytes))) as? [String: Any])
    }
    XCTAssertNotNil(try request("tools/list")["error"])
    _ = try request("initialize", ["protocolVersion": "2025-11-25"])
    let initialized = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])
    XCTAssertNil(server.reply(to: initialized))
    let tools = try XCTUnwrap((request("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.compactMap { $0["name"] as? String }, QueryToolContract.names)
    XCTAssertEqual(tools.count, 5)
    for tool in tools {
      XCTAssertEqual((tool["annotations"] as? [String: Bool])?["readOnlyHint"], true)
      XCTAssertEqual((tool["annotations"] as? [String: Bool])?["destructiveHint"], false)
    }
    for name in ["write", "delete", "propose_delete", "sql", "Bash", "timeline"] {
      XCTAssertNotNil(try request("tools/call", ["name": name, "arguments": [:]])["error"])
    }
    for method in ["resources/list", "resources/read", "prompts/get", "settings/write"] {
      XCTAssertNotNil(try request(method)["error"])
    }
    for args: [String: Any] in [["from": true, "to": 15000], ["from": 14400.5, "to": 15000],
      ["from": 14400, "to": 15000, "sql": "Invented secret"], ["from": "Invented secret", "to": 15000]] {
      let reply = try request("tools/call", ["name": "recent_work", "arguments": args])
      XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true)
      XCTAssertFalse(String(describing: reply).contains("Invented secret"))
    }
    let day = try request("tools/call", ["name": "day_summary", "arguments": ["at": start]])
    XCTAssertEqual((day["result"] as? [String: Any])?["isError"] as? Bool, false)
    allowed = false
    XCTAssertNotNil(try request("tools/list")["error"])
    XCTAssertNotNil(try request("tools/call", ["name": "day_summary", "arguments": ["at": start]])["error"])
  }
}
