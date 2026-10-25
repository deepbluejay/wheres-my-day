import Core
import Darwin
import Foundation
import Outbound

/// No settings mutations, summaries, model calls, or access-history writes exist on this path.
public final class ActivityQueryServer {
  public static let lineLimit = LinePipe.defaultLineLimit
  private static let latestProtocolVersion = "2025-11-25"
  private static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18", latestProtocolVersion]
  private let queries: ActivityQueries
  private let authorized: () -> Bool
  private var initialized = false
  public init(queries: ActivityQueries, authorized: @escaping () -> Bool) {
    self.queries = queries; self.authorized = authorized
  }
  public static func leaseIsValid(environment: [String: String], at now: Int) -> Bool {
    guard let path = environment[QueryToolContract.leaseVariable], path.hasPrefix("/"),
      let token = environment[QueryToolContract.tokenVariable], !token.isEmpty,
      let database = environment[QueryToolContract.databaseVariable], database.hasPrefix("/") else { return false }
    guard (try? FileLocation.validate(database)) != nil else { return false }
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_size <= 4096,
      let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let lease = try? JSONDecoder().decode(QueryRunLease.self, from: bytes),
      lease.token == token,
      (try? FileLocation.validate(lease.database)) != nil,
      let expected = try? FileLocation.key(URL(fileURLWithPath: lease.database)),
      let actual = try? FileLocation.key(URL(fileURLWithPath: database)), expected == actual, lease.expiresAt > now,
      lease.ownerPID > 1, kill(lease.ownerPID, 0) == 0 else { return false }
    return true
  }
  public func reply(to data: Data) -> Data? {
    var id: Any?
    func result(_ value: [String: Any]) -> Data? {
      var reply: [String: Any] = ["jsonrpc": "2.0", "result": value]
      reply["id"] = id
      return try? JSONSerialization.data(withJSONObject: reply, options: .sortedKeys)
    }
    func error(_ code: Int, _ message: String) -> Data? {
      var reply: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
      reply["id"] = id
      return try? JSONSerialization.data(withJSONObject: reply, options: .sortedKeys)
    }
    guard data.count <= Self.lineLimit,
      let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
      return error(-32600, "invalid_request")
    }
    if let value = request["id"] {
      guard value is String || (value is NSNumber && CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID()) else {
        return error(-32600, "invalid_request")
      }
      id = value
    }
    guard authorized() else { return error(-32001, "run_unavailable") }
    if request["id"] == nil { return nil }
    switch method {
    case "initialize":
      guard !initialized else { return error(-32600, "invalid_request") }
      guard let requested = (request["params"] as? [String: Any])?["protocolVersion"] as? String else {
        return error(-32600, "invalid_request")
      }
      // MCP leaves the decision to disconnect after a version fallback to the client.
      let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.latestProtocolVersion
      initialized = true
      return result(["protocolVersion": version, "capabilities": ["tools": ["listChanged": false]],
        "serverInfo": ["name": "ActivityProbe", "version": "1"], "instructions": QueryToolContract.instruction])
    case "ping": return result([:])
    case "tools/list":
      guard initialized else { return error(-32001, "run_unavailable") }
      return result(["tools": QueryToolContract.tools])
    case "tools/call":
      guard initialized else { return error(-32001, "run_unavailable") }
      guard let params = request["params"] as? [String: Any], Set(params.keys).isSubset(of: ["name", "arguments", "_meta"]),
        let name = params["name"] as? String, QueryToolContract.names.contains(name),
        let arguments = params["arguments"] as? [String: Any] else { return error(-32602, "tool_refused") }
      do {
        let answer = try call(name, arguments)
        let encoded = try JSONEncoder().encode(answer)
        guard encoded.count <= 4 * Self.lineLimit else { return error(-32002, "answer_too_large") }
        return result(["content": [["type": "text", "text": String(decoding: encoded, as: UTF8.self)]], "isError": false])
      } catch {
        return result(["content": [["type": "text", "text": "query_unavailable"]], "isError": true])
      }
    default: return error(-32601, "method_refused")
    }
  }
  private func call(_ name: String, _ args: [String: Any]) throws -> ActivityQueryAnswer {
    func integer(_ key: String) throws -> Int {
      guard let number = args[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
        abs(number.doubleValue) <= 9_007_199_254_740_991 else { throw ActivityQueryError.invalidArguments }
      return number.intValue
    }
    let tool = QueryToolContract.tools.first { $0["name"] as? String == name }!
    let schema = tool["inputSchema"] as! [String: Any]
    let keys = Set((schema["properties"] as! [String: Any]).keys)
    guard Set(args.keys).isSubset(of: keys), Set(schema["required"] as! [String]).isSubset(of: Set(args.keys)) else {
      throw ActivityQueryError.invalidArguments
    }
    if name == "day_summary" { return try queries.daySummary(containing: integer("at")) }
    if name == "what_was_i_doing" {
      return try queries.whatWasIDoing(at: integer("at"), minutes: args["minutes"] == nil ? 20 : integer("minutes"))
    }
    let range = try TimeRange(integer("from"), integer("to"))
    switch name {
    case "recent_work": return try queries.recentWork(in: range)
    case "time_breakdown": return try queries.timeTotals(in: range)
    default:
      guard let words = args["query"] as? String else { throw ActivityQueryError.invalidArguments }
      return try queries.search(words, in: range)
    }
  }
  public func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput,
    cancelled: () -> Bool = { false }) {
    do {
      // Answers may contain an escaped 4 MiB query payload. Request bounds stay 1 MiB.
      let pipe = try LinePipe(input: input, output: output, lineLimit: Self.lineLimit,
        outgoingLimit: 8 * Self.lineLimit, receivedLimit: nil)
      while let line = try pipe.readLine(cancelled: cancelled) {
        if let response = reply(to: line) { try pipe.send(response) }
      }
    } catch { return }
  }
}
