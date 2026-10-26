@testable import Core
import Foundation
import Inbound
@testable import Storage

let base = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("cursor-cases.json"))) as! [[String: Any]]
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw NSError(domain: "InventedCursorAdoption", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
var lookups = 0, deferred = 0
for entry in fixtures {
  let folder = base.appendingPathComponent(entry["folder"] as! String)
  let database = folder.appendingPathComponent("invented.sqlite")
  let tool = AgentLogTool(rawValue: entry["tool"] as! String)!
  let files = try AgentLogFiles.listing([folder.path]).files
  let names = entry["names"] as! [String]
  var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: folder, databaseScope: .directory(folder))
  var historical: [String: LogPosition] = [:]
  for file in files { historical[file.path] = try storage.logPosition(path: file.path) }
  try require(historical.count == files.count, "Actual-main raw cursor not found")
  let prompts = try storage.evidence(in: TimeRange(0, 1000))
  try require(prompts.count == files.count, "Expected historical prompts")
  storage = nil
  for _ in 0..<2 {
    for name in names {
      let file = files.first { URL(fileURLWithPath: $0.path).lastPathComponent == name }!
      var recovering = true
      while recovering {
        storage = try ActivityStorage(url: database, appDataDirectory: folder, databaseScope: .directory(folder))
        let position = try storage.logPosition(path: file.path)
        try require(AgentLogPolicy.continues(position, file: file), "Cursor lost physical identity")
        let batch = try AgentLogFiles.read(file, tool: tool, position: position, at: 300)
        try require(batch.events.isEmpty && batch.evidence.isEmpty, "Unchanged historical file replayed")
        try require(batch.position.offset == file.size, "Committed EOF cursor moved")
        try storage.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
        try require(try storage.evidence(in: TimeRange(0, 1000)) == prompts, "Historical evidence changed")
        let old = historical[file.path]!
        try require(try storage.connection.integer("SELECT count(*) FROM log_positions WHERE path=? AND device=? AND inode=? AND offset=? AND state=?",
          [.key(file.path), .integer(old.device), .integer(old.inode), .integer(old.offset), .text(old.state)]) == 1,
          "Historical cursor changed")
        recovering = batch.ownershipDeferred
        deferred += recovering ? 1 : 0
        storage = nil
        lookups += 1
        try require(lookups < 1000, "Recovery failed to converge")
      }
    }
    storage = try ActivityStorage(url: database, appDataDirectory: folder, databaseScope: .directory(folder))
    try require(try storage.connection.integer("SELECT count(*) FROM log_positions") == files.count * 2, "Unexpected cursor count")
    try require(try storage.connection.integer("SELECT count(*) FROM agent_log_events") == 0, "Replayed historical event")
    storage = nil
  }
}
print("Actual-main cursor adoption: \(fixtures.count) fixtures, \(lookups) lookup/restart checks, \(deferred) partial-metadata deferrals, zero replay; historical cursors/evidence unchanged")
