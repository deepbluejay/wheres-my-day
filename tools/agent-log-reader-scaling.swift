import Core
import Darwin
import Foundation
import Inbound
import SQLite3
@testable import Storage

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let size = Int(CommandLine.arguments[2])!
let shape = CommandLine.arguments[3]
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let url = root.appendingPathComponent("invented.jsonl")
FileManager.default.createFile(atPath: url.path, contents: nil)
do {
  let handle = try FileHandle(forWritingTo: url)
  defer { try? handle.close() }
  let unit: String
  let prefix: String
  let suffix: String
  switch shape {
  case "dense":
    prefix = "{\"type\":\"system\",\"noise\":["
    unit = "[],"; suffix = "[]]}\n"
  case "prose":
    prefix = "{\"type\":\"tool\",\"noise\":\""
    unit = "Invented ordinary output. "; suffix = "\"}\n"
  case "unicode":
    prefix = "{\"type\":\"tool\",\"noise\":\""
    unit = "Invented ordinary output. "; suffix = "한🙂\"}\n"
  case "selected":
    prefix = "{\"type\":\"user\",\"timestamp\":\"1970-01-01T00:03:20Z\",\"uuid\":\"invented-selected\",\"message\":{\"role\":\"user\",\"content\":\""
    unit = "Invented ordinary output. "; suffix = "\"}}\n"
  case "flag":
    prefix = "{\"type\":\"tool\",\"origin\":\""
    unit = "Invented ordinary output. "; suffix = "\"}\n"
  case "key":
    prefix = "{\"type\":\"tool\",\""
    unit = "Invented ordinary output. "; suffix = "\":null}\n"
  case "base64":
    prefix = "{\"type\":\"tool\",\"noise\":\""
    unit = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"; suffix = "\"}\n"
  default: fatalError("Unknown invented shape")
  }
  try handle.write(contentsOf: Data(prefix.utf8))
  // Generate in fixed blocks so fixture generation does not inflate measured peak RSS.
  let block = Data(String(repeating: unit, count: max(1, 32768 / unit.utf8.count)).utf8)
  var remaining = max(0, size - prefix.utf8.count - suffix.utf8.count)
  while remaining >= block.count { try handle.write(contentsOf: block); remaining -= block.count }
  try handle.write(contentsOf: Data(String(repeating: unit, count: remaining / unit.utf8.count).utf8))
  try handle.write(contentsOf: Data(suffix.utf8))
}
let source = try AgentLogFiles.listing([root.path]).files[0]
let writerMode = CommandLine.arguments.count > 4 && CommandLine.arguments[4] == "writer"
let storage = writerMode ? try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"),
  appDataDirectory: root, databaseScope: .directory(root)) : nil
final class Trace {
  var start: Date?
  var lockSeconds = 0.0
}
let trace = Trace()
if let storage {
  sqlite3_trace_v2(storage.connection.handle, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
    let trace = Unmanaged<Trace>.fromOpaque(context!).takeUnretainedValue()
    let sql = String(cString: sqlite3_sql(OpaquePointer(statement!)))
    if sql == "BEGIN IMMEDIATE" { trace.start = Date() }
    if sql == "COMMIT", let start = trace.start { trace.lockSeconds += Date().timeIntervalSince(start) }
    return 0
  }, Unmanaged.passUnretained(trace).toOpaque())
}
func cpuSeconds() -> Double {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
    + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
let cpuStart = cpuSeconds()
let start = Date()
let batch = try AgentLogFiles.read(source, tool: .claude, position: nil, at: 200)
let elapsed = Date().timeIntervalSince(start)
let readCPU = cpuSeconds() - cpuStart
precondition(batch.events.count == 1 && batch.position.offset == source.size)
let event = batch.events[0]
precondition(event.parseStatus == (shape == "selected" ? "parsed" : "timestampUnknown") && event.byteCount == source.size - 1)
if shape != "base64" { precondition(event.payload.utf8.count == source.size - 1) }
if shape == "prose" || shape == "unicode" { precondition(event.payload.contains("Invented ordinary output.")) }
if shape == "base64" && size > 1024 { precondition(event.payload.contains("[secret]")) }
if shape == "selected" {
  precondition(batch.evidence.count == 1 && batch.evidence[0].text.utf8.count > size - 512)
}
if shape == "flag" { precondition(event.flags.contains { $0.utf8.count > size - 512 }) }
let appendStart = Date()
if let storage {
  _ = try storage.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
  if let start = trace.start { trace.lockSeconds = Date().timeIntervalSince(start) }
  let growth = try storage.agentLogGrowth()
  precondition(growth.events == 1)
  if shape == "selected" {
    let storedBytes = try storage.connection.integer("SELECT length(CAST(text AS BLOB)) FROM evidence WHERE kind='prompt'")
    precondition(storedBytes == batch.evidence[0].text.utf8.count)
  }
}
let appendElapsed = Date().timeIntervalSince(appendStart)
let report: [String: Any] = ["shape": shape, "bytes": source.size, "elapsed": elapsed, "cpu": readCPU,
  "payloadBytes": event.payload.utf8.count, "events": batch.events.count,
  "writer": writerMode, "appendElapsed": appendElapsed, "lockSeconds": trace.lockSeconds]
print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
