// Invented-only external fixture, linked against each revision's actual Storage.
import Core
import Darwin
import Foundation
import SQLite3
@testable import Storage

let mode = CommandLine.arguments[1], root = URL(fileURLWithPath: CommandLine.arguments[2])
let kind = CommandLine.arguments[3]
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
  databaseScope: .directory(root))
if mode == "crash" {
  try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
  if kind == "metadata" {
    let range = TimeRange(100,101), preview = try store.previewDeletion(in: TimeRange(100,101))
    _ = try store.deleteRecords(in: range, confirmation: preview.confirmation)
  }
  // A WAL hook runs after the real SQL commit, before ready acknowledgement.
  // The product sources and writer transaction are not instrumented.
  sqlite3_wal_hook(store.connection.handle, { _, _, _, _ in _exit(73) }, nil)
  let pipeline = CollectionPipeline(writer: store)
  if kind == "screen" {
    precondition(pipeline.offer(payload: ScreenTextPayload(text: "Invented screen", document: "Invented document"),
      at: 100, source: "invented.app", documentKey: "invented-group", runID: nil, attemptID: nil, metadataObservedAt: 102.2))
  } else {
    let events = kind == "input" ? [InputObservation(kind: .move, timestamp: 100.2)] : []
    precondition(pipeline.offer(ActivityObservation(id: "invented-observation", sample: TimeSample(ts: 100,
      bundleID: "invented.app", window: "Invented window", documentKey: "invented-group", document: "Invented document",
      inputEvents: events, observedAt: 102.2))))
  }
  pipeline.drain()
  fatalError("Fixture did not reach post-commit boundary")
} else {
  if mode == "recover-excluded" {
    try store.saveSettings(StorageSettings(excludedApps: ["invented.app"]), at: 300)
  }
  let pipeline = CollectionPipeline(writer: store)
  pipeline.drain()
  precondition(pipeline.offer(payload: ScreenTextPayload(text: "Invented later screen"), at: 200,
    source: "invented.other", documentKey: "", runID: nil, attemptID: nil))
  for _ in 0..<3 { pipeline.drain() }
  var result: [String: Int] = [
    "version": try store.connection.integer("PRAGMA user_version"),
    "screens": try store.connection.integer("SELECT count(*) FROM screen_payloads"),
    "observations": try store.connection.integer("SELECT count(*) FROM sample_observations"),
    "inputs": try store.connection.integer("SELECT count(*) FROM input_batches"),
    "metadata": try store.connection.integer("SELECT count(*) FROM collection_metadata"),
    "ready": try store.collectionFiles().count,
    "failures": pipeline.takeDiagnostics().persistenceFailures]
  if mode == "recover-excluded" {
    result["exclusionRefusals"] = try store.connection.integer("SELECT COALESCE(sum(count),0) FROM collection_policy_refusals WHERE reason LIKE '%excluded_app'")
  }
  print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
}
