import Core
import CryptoKit
import Foundation
@testable import Storage

let base = URL(fileURLWithPath: CommandLine.arguments[1])
var cases = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("cases.json"))) as! [[String: Any]]
cases.append(["name": "invented-proof", "tool": "claude", "lines": [#"{"type":"user","uuid":"invented-proof","timestamp":"1970-01-01T00:03:20Z","message":{"role":"user","content":"Invented proof"}}"#]])
for entry in cases {
  let folder = base.appendingPathComponent(entry["name"] as! String)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let database = folder.appendingPathComponent("invented.sqlite")
  var storage: ActivityStorage! = try ActivityStorage(url: database, appDataDirectory: folder, databaseScope: .directory(folder))
  try storage.saveSettings(StorageSettings(), at: 0)
  if entry["name"] as? String == "invented-proof" {
    try storage.appendSamples([TimeSample(ts: 100, bundleID: "invented.history", window: "Invented history")])
    try storage.appendEvidence([EvidenceText(ts: 101, kind: .screen, source: "invented.history", text: "Invented history")])
    try storage.saveLogPosition(LogPosition(path: folder.appendingPathComponent("invented-history.jsonl").path,
      device: 1, inode: 2, offset: 0, state: "{}", seenAt: 150))
    try storage.appendModelCall(ModelCall(ts: 100, range: TimeRange(60,120), model: "invented", succeeded: false))
    try storage.appendEvidence([EvidenceText(ts: 110, kind: .prompt, source: "invented.history",
      sourceID: "claude:invented-forgotten", text: "Invented forgotten")])
    #if MAIN14
    try storage.appendObservations([ActivityObservation(id: "invented-observation", sample: TimeSample(ts: 90,
      bundleID: "invented.history", window: "Invented window", document: "Invented document",
      inputEvents: [InputObservation(kind: .move, timestamp: 90.2)], observedAt: 90.5))])
    _ = try storage.appendScreenCapture(payload: ScreenTextPayload(text: "Invented screen", document: "Invented document"),
      at: 91, source: "invented.history", documentKey: "invented", project: "", probe: nil)
    #endif
    let range = TimeRange(110,111), preview = try storage.previewDeletion(in: range)
    try storage.deleteRecords(in: range, confirmation: preview.confirmation)
  }
  let tool = AgentLogTool(rawValue: entry["tool"] as! String)!
  var state = AgentLogState()
  var projected: [EvidenceText] = []
  for line in entry["lines"] as! [String] {
    if case .prompt(let prompt) = AgentLogParser.parse(line, tool: tool, file: "invented-original.jsonl", state: &state,
      fingerprint: { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }) { projected.append(prompt) }
  }
  try storage.appendEvidence(projected)
  let count = try storage.connection.integer("SELECT count(*) FROM evidence")
  precondition(count > 0)
  // Main itself must deduplicate and reopen each fixture successfully.
  try storage.appendEvidence(projected)
  let repeatedCount = try storage.connection.integer("SELECT count(*) FROM evidence")
  precondition(repeatedCount == count)
  let version = try storage.connection.integer("PRAGMA user_version")
  precondition(version == Int(CommandLine.arguments[2])!)
  storage = nil
  storage = try ActivityStorage(url: database, appDataDirectory: folder, databaseScope: .directory(folder))
  let reopenedCount = try storage.connection.integer("SELECT count(*) FROM evidence")
  precondition(reopenedCount == count)
  storage = nil
}
print("Actual-main parser/storage fixtures: \(cases.count), repeated append and main reopen passed")
