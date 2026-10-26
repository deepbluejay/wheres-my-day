// Invented, opt-in cost fixture. Compile with the built Core/Storage objects and
// -I .build/debug/Modules -lsqlite3, then pass an owned scratch root and a mode.
import Core
import Darwin
import Foundation
import SQLite3
@testable import Storage

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let mode = CommandLine.arguments[2]
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
let start = 1_800_000_000
func letters(_ number: Int) -> String {
  var value = number, result = ""
  repeat { result = String(UnicodeScalar(97 + value % 26)!) + result; value /= 26 } while value > 0
  return result
}
func payload(_ scene: Int, variation: Double = 0) -> ScreenTextPayload {
  let lines = (0..<120).map { "Invented " + letters(scene) + " " + letters($0) + " " + String(repeating: "literal ", count: 6) }
  return ScreenTextPayload(text: lines.joined(separator: "\n"), observations: lines.enumerated().map { index, line in
    OCRObservation(bounds: OCRBounds(x: 0.1, y: Double(index) / 120 + variation, width: 0.8, height: 0.008), candidates: [OCRCandidate(text: line, confidence: Float(0.9 - variation)), OCRCandidate(text: line + " a", confidence: 0.3), OCRCandidate(text: line + " b", confidence: 0.1)])
  }, languages: ["en-US", "ko-KR"], languageStatus: "supported_automatic", engine: "Vision")
}
if mode == "seed" {
  try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
  let template = String(decoding: try encoder.encode(ActivityObservation(id: "invented", sample: TimeSample(ts: start, bundleID: "invented", window: "Invented metadata", documentKey: "invented-key", document: "file:///invented/document", observedAt: Double(start), windowIdentity: WindowIdentity(processID: 12, windowID: 34), processID: 12, isBrowser: true, isBrowserKnown: true, accessibility: "invented"))), as: UTF8.self)
  for day in 0..<30 {
    let base = start + day * 86400
    // Raw fixture construction intentionally bypasses public ingestion. Measured
    // operations below always enter production public maintenance APIs.
    try store.connection.run("BEGIN IMMEDIATE")
    for scene in 0..<192 {
      let value = payload(day * 192 + scene), json = try screenPayloadJSON(value)
      let textHash = probeHash(value.text), jsonHash = probeHash(json)
      for (hash, content) in [(textHash,value.text),(jsonHash,json)] {
        try store.connection.run("INSERT INTO collection_blobs VALUES(?,?,?)", [.key(hash), .maskedText(content), .integer(base + scene * 150)])
      }
      for occurrence in 0..<10 {
        let time = base + (scene * 10 + occurrence) * 15
        try store.connection.run("INSERT INTO evidence(ts,kind,source,document_key,project,text) VALUES(?,'screen','invented.editor','invented','','')", [.integer(time)])
        let id = Int(sqlite3_last_insert_rowid(store.connection.handle))
        try store.connection.run("INSERT INTO screen_payloads(evidence_id,payload,text_hash,payload_hash,novel_text,occurrence_id) VALUES(?,'',?,?,?,?)", [.integer(id), .key(textHash), .key(jsonHash), .maskedText(occurrence == 0 ? value.text : ""), .key("invented-capture-\(time)")])
      }
    }
    for stride in [1,3] {
      try store.connection.run("""
        WITH RECURSIVE seconds(n) AS (VALUES(0) UNION ALL SELECT n+\(stride) FROM seconds WHERE n+\(stride)<28800)
        INSERT INTO sample_observations(observation_id,ts,payload,observed_ts)
        SELECT 'invented-'||(?1+n)||'-\(stride)',?1+n,
          json_set(?2,'$.id','invented-'||(?1+n)||'-\(stride)','$.sample.ts',?1+n,'$.sample.observedAt',?1+n),?1+n FROM seconds
        """, [.integer(base), .maskedText(template)])
    }
    for second in 0..<8640 {
      let events = (0..<125).map { InputObservation(kind: .move, timestamp: Double(base + second) + Double($0) / 125, sourcePID: 0, monotonicNanoseconds: UInt64(second * 1_000_000_000 + $0 * 8_000_000)) }
      try store.connection.run("INSERT INTO input_batches(observation_id,ts,events) VALUES(?,?,?)", [.key("invented-\(base+second)-1"), .integer(base+second), .blob(CompactInput.encode(events))])
    }
    try store.connection.run("UPDATE collection_ingestion_pending SET bytes=0")
    try store.connection.run("COMMIT")
    _ = store.connection.truncateWAL()
    print("SEED day=\(day+1)")
  }
  print("SEED page_bytes=\(try store.connection.integer("PRAGMA page_count") * store.connection.integer("PRAGMA page_size")) observations=\(try store.connection.integer("SELECT count(*) FROM sample_observations")) input_batches=\(try store.connection.integer("SELECT count(*) FROM input_batches")) captures=\(try store.connection.integer("SELECT count(*) FROM screen_payloads")) blobs=\(try store.connection.integer("SELECT count(*) FROM collection_blobs"))")
} else if mode == "growth" {
  try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
  for count in [0,256,1024,4096] {
    try store.connection.run("DELETE FROM evidence")
    for source in ["invented.editor", "invented.other"] {
      try store.connection.run("DELETE FROM evidence")
      try store.connection.run("INSERT OR IGNORE INTO collection_blobs VALUES('invented-text','Invented',0),('invented-json','{}',0)")
      try store.connection.run("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<?) INSERT INTO evidence(ts,kind,source,document_key,project,text) SELECT x,'screen',?,'','','' FROM n WHERE x<=?", [.integer(count), .text(source), .integer(count)])
      try store.connection.run("INSERT INTO screen_payloads(evidence_id,payload,text_hash,payload_hash,novel_text,occurrence_id) SELECT id,'','invented-text','invented-json','','invented-'||id FROM evidence")
      let began = ProcessInfo.processInfo.systemUptime
      let capture = try store.appendScreenCapture(payload: ScreenTextPayload(text: "Invented new"), at: start, source: "invented.editor", documentKey: "", project: "", probe: nil)
      let elapsed = ProcessInfo.processInfo.systemUptime-began
      precondition(capture.append.stored == 1)
      let occurrences = try store.connection.integer("SELECT count(*) FROM screen_payloads")
      precondition(occurrences == count + 1)
      print("GROWTH old_rows=\(count) same_source=\(source == "invented.editor") public_capture_s=\(elapsed)")
    }
  }
} else if mode == "variant" {
  try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
  let baseline = try store.connection.integer("PRAGMA page_count") * store.connection.integer("PRAGMA page_size")
  for second in 0..<120 {
    let value = payload(0, variation: Double(second) / 100_000)
    _ = try store.appendScreenCapture(payload: value, at: start + second, source: "invented.editor", documentKey: "", project: "", probe: nil)
    let events = (0..<1250).map { InputObservation(kind: .move, timestamp: Double(start + second) + Double($0) / 1250, sourcePID: 0, monotonicNanoseconds: UInt64(second * 1_000_000_000 + $0 * 800_000)) }
    try store.appendObservations([ActivityObservation(id: "invented-\(second)", sample: TimeSample(ts: start+second, bundleID: "invented.editor", inputEvents: events))])
  }
  _ = store.connection.truncateWAL()
  print("VARIANT seconds=120 captures=120 movement_hz=1250 events=150000 changing_bounds_confidence=true added_page_bytes=\(try store.connection.integer("PRAGMA page_count") * store.connection.integer("PRAGMA page_size") - baseline) blobs=\(try store.connection.integer("SELECT count(*) FROM collection_blobs")) compact_bytes=\(try store.connection.integer("SELECT sum(length(events)) FROM input_batches"))")
} else if mode == "validate" {
  let malformed = try store.connection.integer("SELECT count(*) FROM sample_observations WHERE json_extract(payload,'$.id')!=observation_id OR json_extract(payload,'$.sample.ts')!=ts OR json_extract(payload,'$.sample.observedAt')!=observed_ts")
  precondition(malformed == 0)
  var batches = 0, events = 0, blobs = 0
  try store.connection.namedRows("SELECT ts,events FROM input_batches WHERE id%4319=0 LIMIT 58") { row in
    let bytes = try row.data("events"), decoded = try CompactInput.decode(bytes)
    precondition(CompactInput.encode(decoded) == bytes)
    let second = try row.int("ts")
    precondition(decoded.allSatisfy { Int(floor($0.timestamp)) == second })
    batches += 1; events += decoded.count
  }
  try store.connection.namedRows("SELECT hash,content FROM collection_blobs") { row in
    let hash = try row.text("hash"), content = try row.text("content")
    precondition(probeHash(content) == hash); blobs += 1
  }
  print("VALIDATED malformed_observations=0 sampled_batches=\(batches) sampled_events=\(events) blob_hashes=\(blobs)")
} else {
  final class Monitor: @unchecked Sendable {
    let lock = NSLock(); var done = false
    var longest = 0.0, gap = 0.0, logical: Int64 = 0, allocated: Int64 = 0, wal: Int64 = 0
    func stop() { lock.lock(); done = true; lock.unlock() }
    func stopped() -> Bool { lock.lock(); defer { lock.unlock() }; return done }
  }
  if mode == "repair" {
    try store.connection.run("UPDATE screen_payloads SET novel_text=NULL WHERE evidence_id IN (SELECT evidence_id FROM screen_payloads ORDER BY evidence_id DESC LIMIT 320)")
  }
  let monitor = Monitor(), finished = DispatchSemaphore(value: 0)
  let writer = try ActivityStorage(url: store.url, appDataDirectory: root, busyMilliseconds: 0, databaseScope: .directory(root))
  let pipeline = CollectionPipeline(writer: writer)
  let offerSignal = DispatchSemaphore(value: 0), pipelineFinished = DispatchSemaphore(value: 0)
  var signaled = false, published = 0.0, durable = 0.0, offered = 0.0, accepted = false, attempts = 0
  writer.collectionPublicationFault = { if $0 == "after-sync" { published = ProcessInfo.processInfo.systemUptime } }
  store.connection.collectionCommitClock = {
    if !signaled { signaled = true; offerSignal.signal() }
    return Int(Date().timeIntervalSince1970)
  }
  DispatchQueue.global().async {
    offerSignal.wait()
    offered = ProcessInfo.processInfo.systemUptime
    accepted = pipeline.offer(ActivityObservation(id: "invented-concurrent-" + mode + "-" + UUID().uuidString, sample: TimeSample(ts: start + 32 * 86400, bundleID: "invented.allowed", window: "Invented allowed")))
    while ProcessInfo.processInfo.systemUptime-offered < 60 {
      pipeline.drain(); attempts += 1
      if pipeline.takeCompletions().0.contains(where: { $0.storedObservations == 1 }) { durable = ProcessInfo.processInfo.systemUptime; break }
      Thread.sleep(forTimeInterval: 0.001)
      pipeline.retry()
    }
    pipelineFinished.signal()
  }
  let database = store.url.path
  var before = rusage(); getrusage(RUSAGE_SELF, &before)
  DispatchQueue.global().async {
    var writer: OpaquePointer?; sqlite3_open_v2(database, &writer, SQLITE_OPEN_READWRITE, nil)
    defer { sqlite3_close(writer); finished.signal() }
    sqlite3_busy_timeout(writer, 0)
    var blocked: Double?, previous = ProcessInfo.processInfo.systemUptime
    while !monitor.stopped() {
      let now = ProcessInfo.processInfo.systemUptime
      monitor.gap = max(monitor.gap, now-previous); previous = now
      if sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK {
        sqlite3_exec(writer, "ROLLBACK", nil, nil, nil)
        if let since = blocked { monitor.longest = max(monitor.longest, now-since); blocked = nil }
      } else { if blocked == nil { blocked = now } }
      var logical: Int64 = 0, allocated: Int64 = 0
      for fd in 0..<min(getdtablesize(), 512) {
        var status = stat()
        if fstat(fd, &status) == 0 && status.st_mode & S_IFMT == S_IFREG && status.st_nlink == 0 {
          logical += status.st_size; allocated += Int64(status.st_blocks) * 512
        }
      }
      monitor.logical = max(monitor.logical, logical); monitor.allocated = max(monitor.allocated, allocated)
      var wal = stat(); if stat(database + "-wal", &wal) == 0 { monitor.wal = max(monitor.wal, wal.st_size) }
      Thread.sleep(forTimeInterval: 0.001)
    }
    if let since = blocked { monitor.longest = max(monitor.longest, ProcessInfo.processInfo.systemUptime-since) }
  }
  var began = ProcessInfo.processInfo.systemUptime
  if mode == "noop" || mode == "repair" { _ = try store.cleanRetention(at: start + 30 * 86400) }
  else if mode == "forget" || mode == "forget-day" {
    let previewStart = ProcessInfo.processInfo.systemUptime
    let range = mode == "forget-day" ? TimeRange(start+86400,start+2*86400) : TimeRange(start+100,start+101)
    let preview = try store.previewDeletion(in: range)
    print("PREVIEW seconds=\(ProcessInfo.processInfo.systemUptime-previewStart)")
    began = ProcessInfo.processInfo.systemUptime
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
  } else if mode == "day" { _ = try store.cleanRetention(at: start + 31 * 86400) }
  else if mode == "capture" {
    _ = try store.appendScreenCapture(payload: payload(99999), at: start + 32 * 86400, source: "invented.editor", documentKey: "", project: "", probe: nil)
  } else if mode == "tick" {
    _ = try store.appendAccountingSamples([TimeSample(ts: start + 32 * 86400, bundleID: "invented.editor", window: "Invented tick")])
  } else { fatalError("Unknown invented-fixture mode") }
  let elapsed = ProcessInfo.processInfo.systemUptime-began
  if !signaled { signaled = true; offerSignal.signal() }
  pipelineFinished.wait()
  let observationPublished = published
  if mode == "capture" {
    let value = payload(99998)
    let since = ProcessInfo.processInfo.systemUptime
    precondition(pipeline.offer(payload: value, at: start + 32 * 86400 + 1, source: "invented.editor", documentKey: "", runID: nil, attemptID: nil))
    var captureDone = false, drains = 0
    repeat {
      pipeline.drain(); drains += 1
      captureDone = pipeline.takeCompletions().0.contains { $0.screen?.append.stored == 1 }
      if !captureDone { Thread.sleep(forTimeInterval: 0.001); pipeline.retry() }
    } while !captureDone && ProcessInfo.processInfo.systemUptime-since < 60
    precondition(captureDone)
    print("PIPELINE_CAPTURE publish_delay_s=\(published-since) durable_ack_delay_s=\(ProcessInfo.processInfo.systemUptime-since) drain_attempts=\(drains)")
  }
  monitor.stop(); finished.wait()
  let diagnostics = pipeline.takeDiagnostics()
  precondition(accepted && published > 0 && durable > 0)
  print("PIPELINE mode=\(mode) accepted=\(accepted) publish_delay_s=\(observationPublished-offered) durable_ack_delay_s=\(durable-offered) committed_before_operation_end=\(durable < began+elapsed) drain_attempts=\(attempts) staging_failures=\(diagnostics.stagingFailures) persistence_failures=\(diagnostics.persistenceFailures)")
  var after = rusage(); getrusage(RUSAGE_SELF, &after)
  print("MAINTENANCE mode=\(mode) wall_s=\(elapsed) longest_sqlite_writer_refusal_s=\(monitor.longest) max_probe_gap_s=\(monitor.gap) anonymous_logical_peak=\(monitor.logical) anonymous_allocated_peak=\(monitor.allocated) wal_peak=\(monitor.wal) starting_peak_rss=\(before.ru_maxrss) peak_rss=\(after.ru_maxrss)")
  print("REMAIN observations=\(try store.connection.integer("SELECT count(*) FROM sample_observations")) input_batches=\(try store.connection.integer("SELECT count(*) FROM input_batches")) captures=\(try store.connection.integer("SELECT count(*) FROM screen_payloads")) blobs=\(try store.connection.integer("SELECT count(*) FROM collection_blobs"))")
}
