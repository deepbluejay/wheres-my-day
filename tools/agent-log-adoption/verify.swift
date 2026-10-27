@testable import Core
import Foundation
import Inbound
import SQLite3
@testable import Storage

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw NSError(domain: "InventedAdoption", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
var originalColumns: [String: [String]] = [:]
func snapshot(_ storage: ActivityStorage, _ table: String) throws -> [Data] {
  var result: [Data] = []
  if originalColumns[table] == nil {
    var columns: [String] = []
    try storage.connection.namedRows("PRAGMA table_info(\(table))") { columns.append(try $0.text("name")) }
    originalColumns[table] = columns
  }
  let selection = originalColumns[table]!.map { "\"\($0)\"" }.joined(separator: ",")
  try storage.connection.rows("SELECT \(selection) FROM \(table) ORDER BY 1,2") { row in
    var bytes = Data()
    for column in 0..<sqlite3_column_count(row) {
      bytes.append(UInt8(sqlite3_column_type(row,column)))
      let count = sqlite3_column_bytes(row,column)
      bytes.append(Data("\(count):".utf8))
      if let data = sqlite3_column_blob(row,column) { bytes.append(Data(bytes: data,count: Int(count))) }
    }
    result.append(bytes)
  }
  return result
}
let base = URL(fileURLWithPath: CommandLine.arguments[1])
let modern = CommandLine.arguments.dropFirst(2).contains("15")
let pinnedControl = CommandLine.arguments.contains("--control")
let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("cases.json"))) as! [[String: Any]]
var copied = 0, forgotten = 0, independent = 0
for entry in cases {
  let folder = base.appendingPathComponent(entry["name"] as! String)
  let database = folder.appendingPathComponent("invented.sqlite")
  let old = try ActivityStorage(url: database, appDataDirectory: folder, readOnly: true, databaseScope: .directory(folder))
  let originals = try snapshot(old, "evidence")
  let historicalTables = ["forgotten_sources", "forgotten_ranges", "settings", "log_recording_history", "log_positions"]
  let historicalRows = try historicalTables.map { try snapshot(old, $0) }
  let oldForgotten = Set(try snapshot(old, "forgotten_sources"))
  var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: folder, databaseScope: .directory(folder))
  try require(try snapshot(storage, "evidence") == originals, "Adoption changed historical evidence")
  for (table, rows) in zip(historicalTables, historicalRows) {
    try require(try snapshot(storage, table) == rows, "Adoption changed historical \(table)")
  }
  func reopen() throws {
    storage = nil
    storage = try ActivityStorage(url: database, appDataDirectory: folder, databaseScope: .directory(folder))
  }
  let tool = AgentLogTool(rawValue: entry["tool"] as! String)!
  func acquire(_ lines: [String], _ name: String) throws {
    let file = folder.appendingPathComponent(name + ".jsonl")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    let source = try AgentLogFiles.listing([folder.path]).files.first { $0.path == file.path }!
    var position: LogPosition?
    repeat {
      let batch = try AgentLogFiles.read(source,tool: tool,position: position,at: 300,
        ownSources: AgentLogFiles.ownSources(appDataDirectory: folder))
      try storage.appendLogEvents(batch.events,evidence: batch.evidence,position: batch.position)
      position = batch.position
    } while position!.offset < source.size
  }
  try reopen()
  _ = storage.connection.truncateWAL()
  let order = entry["copied_first"] as? Bool == true ? ["invented-copy", "invented-original"] : ["invented-original", "invented-copy"]
  for name in order {
    try acquire(entry["lines"] as! [String], name)
    if entry["independent"] as? Bool != true {
      try require(try snapshot(storage,"evidence") == originals, "Copy duplicated or rewrote historical content: \(entry["name"]!)")
    } else {
      let all = Set(try snapshot(storage,"evidence"))
      try require(originals.allSatisfy { all.contains($0) }, "Independent copy rewrote history")
    }
    try reopen(); copied += 1
  }
  if entry["retention"] as? Bool == true {
    try storage.cleanRetention(at: 10_000_000)
    try require(try storage.connection.integer("SELECT count(*) FROM agent_log_legacy_evidence_keys") == 0, "Retention receipt orphan")
    try require(try storage.connection.integer("SELECT count(*) FROM agent_log_legacy_compatibility") == 0, "Retention compatibility orphan")
    try reopen()
    try acquire(entry["future"] as! [String], "invented-after-retention")
    try require(try storage.connection.integer("SELECT count(*) FROM evidence") > 0, "Retention created a refusal")
  } else {
    let preview = try storage.previewDeletion(in: TimeRange(200, 203))
    try storage.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    try reopen()
    let modernIndependent = modern && entry["independent"] as? Bool == true
    for (index, name) in ["invented-future", "invented-restarted-future"].enumerated() {
      try acquire(entry["future"] as! [String], name)
      try require(try storage.connection.integer("SELECT count(*) FROM evidence") == (modernIndependent ? 1 : 0), "Future forget resurrected evidence: \(entry["name"]!)")
      try require(try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE ts>=204 AND role='user'") == (modernIndependent ? index + 1 : 0), "Future forget resurrected occurrence: \(entry["name"]!)")
      try reopen(); forgotten += 1
    }
    if modernIndependent {
      // Main 15 already separated implicit deliveries into their own native IDs.
      // A new child remains independent; replay of the forgotten child stays refused.
      try require(try storage.connection.integer("SELECT count(*) FROM evidence WHERE source_id=?",
        [.key(AgentLogIdentity.claude("invented-future-child"))]) == 1, "Independent future native child missing")
      let originalChild = (entry["future"] as! [String]).map {
        $0.replacingOccurrences(of: "invented-future-child", with: "invented-child")
      }
      try acquire(originalChild, "invented-forgotten-native-child")
      try require(try storage.connection.integer("SELECT count(*) FROM evidence") == 1, "Forgotten original native child returned")
      try require(try storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE ts>=204 AND role='user'") == 2,
        "Forgotten original native occurrence returned")
      independent += 1
    }
    if let secret = entry["forbidden"] as? String {
      for table in ["forgotten_sources", "agent_log_legacy_evidence_keys", "agent_log_legacy_refusals", "agent_log_legacy_compatibility", "agent_log_content_keys"] {
        for row in try snapshot(storage,table) where table != "forgotten_sources" || !oldForgotten.contains(row) {
          try require(row.range(of: Data(secret.utf8)) == nil, "Reversible secret in new receipt")
        }
      }
      if !oldForgotten.contains(where: { $0.range(of: Data(secret.utf8)) != nil }),
        let wal = try? Data(contentsOf: URL(fileURLWithPath: database.path + "-wal")) {
        try require(wal.range(of: Data(secret.utf8)) == nil, "Reversible secret in new WAL pages")
      }
    }
  }
  storage = nil
}
print("\(pinnedControl ? "Pinned-main-15 control" : "Actual-main adoption"): \(cases.count) fixtures, \(copied) copy/order/restart checks, \(forgotten) future-forget checks, \(independent) independent-native controls; preserved every historical evidence byte/type")
