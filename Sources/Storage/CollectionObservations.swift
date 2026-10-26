import Core
import Foundation
import SQLite3

func screenPayloadJSON(_ payload: ScreenTextPayload) throws -> String {
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
  return String(decoding: try encoder.encode(payload), as: UTF8.self)
}

extension SQLiteConnection {
  static let collectionCascadeTriggers = [
    "CREATE TRIGGER IF NOT EXISTS collection_legacy_delete AFTER DELETE ON sample_observations BEGIN DELETE FROM collection_legacy_times WHERE observation_row=OLD.id; END",
    "CREATE TRIGGER IF NOT EXISTS screen_payload_update_owner BEFORE UPDATE OF evidence_id ON screen_payloads WHEN NEW.evidence_id!=OLD.evidence_id OR NOT EXISTS(SELECT 1 FROM evidence WHERE id=NEW.evidence_id) BEGIN SELECT RAISE(ABORT,'Screen ownership is immutable'); END",
    "CREATE TRIGGER IF NOT EXISTS screen_payload_owner BEFORE INSERT ON screen_payloads WHEN NOT EXISTS(SELECT 1 FROM evidence WHERE id=NEW.evidence_id) BEGIN SELECT RAISE(ABORT,'Missing screen occurrence'); END",
    "CREATE TRIGGER IF NOT EXISTS screen_payload_delete AFTER DELETE ON evidence BEGIN DELETE FROM screen_payloads WHERE evidence_id=OLD.id; END",
    "CREATE TRIGGER IF NOT EXISTS collection_unref AFTER DELETE ON screen_payloads BEGIN DELETE FROM collection_blobs WHERE hash IN (OLD.text_hash,OLD.payload_hash) AND NOT EXISTS(SELECT 1 FROM screen_payloads WHERE text_hash=hash OR payload_hash=hash); END"
  ]
  func createCollectionSchema() throws {
    try requireCollectionMaintenance()
    try run("""
      CREATE TABLE IF NOT EXISTS sample_observations (
        id INTEGER PRIMARY KEY, observation_id TEXT NOT NULL UNIQUE, ts INTEGER NOT NULL, payload TEXT NOT NULL)
      """)
    try run("CREATE TABLE IF NOT EXISTS collection_retention(id INTEGER PRIMARY KEY CHECK(id=1),screen_cutoff INTEGER NOT NULL)")
    try run("CREATE TABLE IF NOT EXISTS collection_policy_refusals(reason TEXT PRIMARY KEY,count INTEGER NOT NULL)")
    try run("CREATE TABLE IF NOT EXISTS collection_metadata(id INTEGER PRIMARY KEY,identity TEXT NOT NULL UNIQUE,ts INTEGER NOT NULL,source TEXT NOT NULL,document_key TEXT NOT NULL,payload TEXT NOT NULL)")
    try run("CREATE INDEX IF NOT EXISTS collection_metadata_time ON collection_metadata(ts)")
    try run("CREATE INDEX IF NOT EXISTS sample_observations_time ON sample_observations(ts)")
    try run("""
      CREATE TABLE IF NOT EXISTS screen_payloads (
        evidence_id INTEGER PRIMARY KEY, payload TEXT NOT NULL)
      """)
    var columns = Set<String>()
    try namedRows("PRAGMA table_info(sample_observations)") { columns.insert(try $0.text("name")) }
    if !columns.contains("observed_ts") { try run("ALTER TABLE sample_observations ADD COLUMN observed_ts INTEGER") }
    if !columns.contains("legacy_timing") {
      try run("ALTER TABLE sample_observations ADD COLUMN legacy_timing INTEGER NOT NULL DEFAULT 0")
      try collectionWrite("UPDATE sample_observations SET legacy_timing=1 WHERE COALESCE(json_array_length(payload,'$.sample.inputEvents'),0)>0 OR (observed_ts IS NULL AND json_extract(payload,'$.sample.observedAt') IS NOT NULL)")
    }
    try run("CREATE INDEX IF NOT EXISTS sample_observations_legacy ON sample_observations(id) WHERE legacy_timing=1")
    var sampleColumns = Set<String>()
    try namedRows("PRAGMA table_info(samples)") { sampleColumns.insert(try $0.text("name")) }
    if !sampleColumns.contains("observed_ts") { try run("ALTER TABLE samples ADD COLUMN observed_ts INTEGER") }
    try run("CREATE INDEX IF NOT EXISTS samples_observed ON samples(observed_ts,id)")
    try run("CREATE INDEX IF NOT EXISTS sample_observations_observed ON sample_observations(observed_ts,id)")
    try run("CREATE INDEX IF NOT EXISTS evidence_time_id ON evidence(ts,id)")
    columns = []
    try namedRows("PRAGMA table_info(screen_payloads)") { columns.insert(try $0.text("name")) }
    for name in ["text_hash", "payload_hash", "novel_text", "occurrence_id", "metadata_time"] where !columns.contains(name) {
      try run("ALTER TABLE screen_payloads ADD COLUMN \(name) TEXT")
    }
    if !columns.contains("metadata_ts") { try run("ALTER TABLE screen_payloads ADD COLUMN metadata_ts INTEGER") }
    if !columns.contains("novelty_rebuild_failed") { try run("ALTER TABLE screen_payloads ADD COLUMN novelty_rebuild_failed INTEGER NOT NULL DEFAULT 0") }
    for sql in [
      "CREATE TABLE IF NOT EXISTS collection_legacy_times(id INTEGER PRIMARY KEY,observation_row INTEGER NOT NULL,ts INTEGER NOT NULL,UNIQUE(observation_row,ts))",
      "CREATE INDEX IF NOT EXISTS collection_legacy_time ON collection_legacy_times(ts,observation_row)",
      "CREATE TABLE IF NOT EXISTS collection_blobs(hash TEXT PRIMARY KEY,content TEXT NOT NULL,created_ts INTEGER NOT NULL)",
      "CREATE INDEX IF NOT EXISTS collection_blob_created ON collection_blobs(created_ts)",
      "CREATE INDEX IF NOT EXISTS screen_metadata_time ON screen_payloads(metadata_ts,evidence_id)",
      "CREATE INDEX IF NOT EXISTS screen_pending_novelty ON screen_payloads(evidence_id) WHERE novel_text IS NULL",
      "CREATE UNIQUE INDEX IF NOT EXISTS screen_occurrence_identity ON screen_payloads(occurrence_id) WHERE occurrence_id IS NOT NULL",
      "CREATE INDEX IF NOT EXISTS screen_text_ref ON screen_payloads(text_hash)",
      "CREATE INDEX IF NOT EXISTS screen_payload_ref ON screen_payloads(payload_hash)",
      "CREATE TABLE IF NOT EXISTS input_batches(id INTEGER PRIMARY KEY,observation_id TEXT NOT NULL,ts INTEGER NOT NULL,events BLOB NOT NULL,UNIQUE(observation_id,ts))",
      "CREATE INDEX IF NOT EXISTS input_batches_time ON input_batches(ts,id)",
    ] { try run(sql) }
    for sql in Self.collectionCascadeTriggers { try run(sql) }
  }
}
extension SQLiteConnection {
  func backfillCollectionNovelty() throws {
    try requireCollectionMaintenance()
    try collectionWrite("UPDATE sample_observations SET legacy_timing=1 WHERE COALESCE(json_array_length(payload,'$.sample.inputEvents'),0)>0")
    try collectionWrite("INSERT OR IGNORE INTO collection_legacy_times(observation_row,ts) SELECT o.id,CAST(json_extract(j.value,'$.timestamp') AS INTEGER) FROM sample_observations o,json_each(o.payload,'$.sample.inputEvents') j")
    try collectionWrite("UPDATE sample_observations SET observed_ts=CAST(json_extract(payload,'$.sample.observedAt') AS INTEGER) WHERE observed_ts IS NULL")
    // Main's schema-9 samples have no observation rows. Adoption must not rewrite them.
    try collectionWrite("""
      UPDATE samples SET observed_ts=(SELECT observed_ts FROM sample_observations WHERE ts=samples.ts ORDER BY id LIMIT 1)
      WHERE observed_ts IS NULL AND (SELECT observed_ts FROM sample_observations WHERE ts=samples.ts ORDER BY id LIMIT 1) IS NOT NULL
      """)
    try collectionWrite("""
      UPDATE screen_payloads SET metadata_ts=COALESCE(
        (SELECT MIN(o.observed_ts) FROM sample_observations o JOIN evidence e ON e.id=screen_payloads.evidence_id
          WHERE o.ts=e.ts AND json_extract(o.payload,'$.sample.bundleID')=e.source
            AND json_extract(o.payload,'$.sample.document') IS json_extract(CASE WHEN json_valid(screen_payloads.payload) THEN screen_payloads.payload ELSE '{}' END,'$.document')
            AND json_extract(o.payload,'$.sample.browserAddress') IS json_extract(CASE WHEN json_valid(screen_payloads.payload) THEN screen_payloads.payload ELSE '{}' END,'$.browserAddress')),
        (SELECT ts FROM evidence WHERE id=evidence_id))
      WHERE metadata_ts IS NULL AND (json_extract(CASE WHEN json_valid(payload) THEN payload ELSE '{}' END,'$.document') IS NOT NULL OR json_extract(CASE WHEN json_valid(payload) THEN payload ELSE '{}' END,'$.browserAddress') IS NOT NULL
        OR EXISTS(SELECT 1 FROM evidence WHERE id=evidence_id AND document_key!=''))
      """)
    var memory = ScreenKeyMemory()
    try namedRows("SELECT e.id,e.ts,e.text,p.evidence_id FROM evidence e LEFT JOIN screen_payloads p ON p.evidence_id=e.id WHERE kind='screen' ORDER BY ts,id") { row in
      let time = try row.int("ts"), text = try row.text("text")
      memory.expire(at: time)
      let complete = try row.int("evidence_id") != 0
      let selection = complete ? ScreenLines.select(maskedText: text, knownKeys: memory.keys).lines.joined(separator: "\n") : text
      if complete { try collectionWrite("UPDATE screen_payloads SET novel_text=? WHERE evidence_id=? AND novel_text IS NULL", [.maskedText(selection), .integer(try row.int("id"))]) }
      memory.add(Set(selection.components(separatedBy: .newlines).filter { !$0.isEmpty }.map(ScreenLineKey.fromMaskedLine)), storedAt: time, now: time)
    }
  }
}
extension ActivityStorage {
  func permittedInputEvents(_ events: [InputObservation]) throws -> [InputObservation] {
    var seconds: [Int: Bool] = [:]
    return try events.filter { event in
      let second = try collectionSecond(event.timestamp)
      if let allowed = seconds[second] { return allowed }
      let allowed = try collectionRefusal(at: second) == nil
      seconds[second] = allowed; return allowed
    }
  }

  @discardableResult public func appendAccountingSamples(_ samples: [TimeSample]) throws -> AppendResult {
    try locked { try connection.transaction {
      var result = AppendResult()
      for sample in samples {
        if try insertSample(sample) { result.stored += 1 } else { result.refused += 1 }
      }
      return result
    } }
  }

  @discardableResult func insertObservation(_ observation: ActivityObservation) throws -> Bool {
    try withCollectionAdmission(CollectionRecord(observation: observation, time: observation.sample.ts,
      observationEvents: CompactInput.encode(observation.sample.inputEvents))) { try insertAdmittedObservation($0) }
  }
  @discardableResult func insertAdmittedObservation(_ record: CollectionRecord) throws -> Bool {
    var value = record.observation!
    value.sample.inputEvents = try record.observationEvents.map(CompactInput.decode) ?? []
    if record.eventsOnly == true {
      try insertAdmittedInputEvents(value.sample.inputEvents, observationID: value.id, applicationIdentity: value.applicationPrivacyIdentity, record: record)
      try insertIndependentMetadata(record)
      return false
    }
    let time = value.sample.ts
    let events = value.sample.inputEvents
    value.sample.inputEvents = []
    let payload = try record.observationJSON(value)
    try connection.collectionWrite("INSERT OR IGNORE INTO sample_observations(observation_id,ts,payload,observed_ts) VALUES(?,?,?,?)",
      [.key(value.id), .integer(time), .maskedText(payload), value.sample.observedAt.map { .integer(Int(floor($0))) } ?? .null])
    let inserted = sqlite3_changes(connection.handle) == 1
    let insertedID = Int(sqlite3_last_insert_rowid(connection.handle))
    try insertAdmittedInputEvents(events, observationID: value.id, applicationIdentity: value.applicationPrivacyIdentity, record: record)
    var verified = false
    try connection.namedRows("SELECT ts,payload,observed_ts FROM sample_observations WHERE observation_id=?", [.key(value.id)]) { row in
      let storedJSON = try row.text("payload")
      if inserted && storedJSON != payload { throw StorageError("Observation payload differs") }
      let stored = try JSONDecoder().decode(ActivityObservation.self, from: Data(storedJSON.utf8))
      let existing = try admitCollection(CollectionRecord(observation: stored, time: stored.sample.ts)).record.observation!
      let observedMatches: Bool
      if let observed = stored.sample.observedAt {
        if case .integer(let second) = try row.value("observed_ts") { observedMatches = try second == collectionSecond(observed) }
        else { observedMatches = false }
      }
      else { if case .null = try row.value("observed_ts") { observedMatches = true } else { observedMatches = false } }
      if case .integer(let second) = try row.value("ts") { verified = second == time && existing == value && observedMatches }
    }
    guard verified else {
      if !inserted { throw CollectionReplayFailure() }
      throw StorageError("Observation identity or content was not stored")
    }
    if inserted {
      try connection.proveCollectionRows("observation:" + value.id, adding:
        "SELECT * FROM sample_observations WHERE observation_id=? AND id=? AND typeof(id)='integer' AND typeof(observation_id)='text' AND typeof(ts)='integer' AND ts=? AND typeof(payload)='text' AND payload=? AND observed_ts IS ? AND (observed_ts IS NULL OR typeof(observed_ts)='integer') AND typeof(legacy_timing)='integer' AND legacy_timing=0",
        [.key(value.id), .integer(insertedID), .integer(time), .maskedText(payload), value.sample.observedAt.map { .integer(Int(floor($0))) } ?? .null])
    } else { try connection.verifyCollectionRows("observation:" + value.id) }
    return inserted
  }
  @discardableResult public func appendObservations(_ observations: [ActivityObservation]) throws -> AppendResult {
    try locked { try connection.transaction {
      var result = AppendResult()
      let admissions = try prepareCollectionTransaction(observations.map {
        CollectionRecord(observation: $0, time: $0.sample.ts, observationEvents: CompactInput.encode($0.sample.inputEvents))
      })
      for admission in admissions {
        if try writeCollectionAdmission(admission, { try insertAdmittedObservation($0) }) { result.stored += 1 } else { result.refused += 1 }
      }
      return result
    } }
  }
  public func observations(in range: TimeRange) throws -> [ActivityObservation] {
    try locked {
      var result: [ActivityObservation] = []
      try connection.namedRows("SELECT payload FROM sample_observations WHERE ts>=? AND ts<? ORDER BY ts,id",
        [.integer(range.start), .integer(range.end)]) {
        var observation = try JSONDecoder().decode(ActivityObservation.self, from: Data(try $0.text("payload").utf8))
        try connection.namedRows("SELECT events FROM input_batches WHERE observation_id=? ORDER BY ts,id", [.key(observation.id)]) {
          observation.sample.inputEvents += try CompactInput.decode($0.data("events"))
        }
        result.append(observation)
      }
      return result
    }
  }
  @discardableResult public func appendScreenCapture(payload: ScreenTextPayload, at time: Int, source: String,
    documentKey: String, project: String, probe: AXProbeLink?) throws -> ScreenCaptureResult {
    return try storeScreenCapture(text: payload.text, at: time, source: source,
      documentKey: documentKey, project: project, knownKeys: [], probe: probe, payload: payload)
  }
  public func screenPayload(evidenceID: Int) throws -> ScreenTextPayload? {
    try locked {
      var result: ScreenTextPayload?
      try connection.namedRows("SELECT COALESCE(b.content,p.payload) AS payload FROM screen_payloads p LEFT JOIN collection_blobs b ON b.hash=p.payload_hash WHERE evidence_id=?", [.integer(evidenceID)]) {
        result = try JSONDecoder().decode(ScreenTextPayload.self, from: Data(try $0.text("payload").utf8))
      }
      return result
    }
  }
  /// Selection is immutable per occurrence, so pruning a prefix cannot change summaries.
  public func novelEvidence(in range: TimeRange) throws -> [EvidenceText] {
    try locked {
      guard try connection.integer("SELECT count(*) FROM evidence e JOIN screen_payloads p ON p.evidence_id=e.id WHERE e.ts>=? AND e.ts<? AND p.novel_text IS NULL", [.integer(range.start), .integer(range.end)]) == 0 else {
        throw StorageError("Screen compatibility selection awaits write-time repair")
      }
      var result: [EvidenceText] = []
      try connection.namedRows("""
        SELECT e.ts,e.kind,e.source,e.source_id,e.document_key,e.project,
          COALESCE(p.novel_text,e.text) AS text FROM evidence e
        LEFT JOIN screen_payloads p ON p.evidence_id=e.id
        WHERE e.ts>=? AND e.ts<? AND COALESCE(p.novel_text,e.text)!='' ORDER BY e.ts,e.id
        """, [.integer(range.start), .integer(range.end)]) {
        result.append(EvidenceText(ts: try $0.int("ts"), kind: EvidenceKind(rawValue: try $0.text("kind"))!,
          source: try $0.text("source"), sourceID: try $0.optionalText("source_id"),
          documentKey: try $0.text("document_key"), project: try $0.text("project"), text: try $0.text("text")))
      }
      return result
    }
  }
  // Derived repair has its own proof and rollback. Its failure must not prevent
  // the following ingestion transaction from saving a newly acquired capture.
  func repairPendingCollectionNovelty() {
    guard noveltyKeyReader == nil,
      (try? connection.integer("SELECT EXISTS(SELECT 1 FROM screen_payloads WHERE novel_text IS NULL)")) == 1 else { return }
    _ = try? connection.transaction(collectionMaintenance: true) { try repairCollectionNovelty() }
  }
  /// Only failed write-time selections need repair. Healthy reads never replay captures.
  func repairCollectionNovelty(limit: Int? = 32) throws {
    try connection.requireCollectionMaintenance()
    var pending: [(Int, Int)] = []
    let bound = limit.map { " LIMIT \($0)" } ?? ""
    try connection.namedRows("SELECT e.id,e.ts FROM screen_payloads p JOIN evidence e ON e.id=p.evidence_id WHERE p.novel_text IS NULL ORDER BY e.ts,e.id" + bound) {
      pending.append((try $0.int("id"), try $0.int("ts")))
    }
    guard let first = pending.first?.1, let last = pending.last else { return }
    let start = first > Int.min + RecorderTiming.lineMemorySeconds ? first - RecorderTiming.lineMemorySeconds : Int.min
    var memory = ScreenKeyMemory()
    try connection.namedRows("""
      SELECT e.id,e.ts,e.text,p.evidence_id,p.novel_text,b.content
      FROM evidence e LEFT JOIN screen_payloads p ON p.evidence_id=e.id
      LEFT JOIN collection_blobs b ON b.hash=p.text_hash
      WHERE e.kind='screen' AND e.ts>=? AND (e.ts<? OR (e.ts=? AND e.id<=?)) ORDER BY e.ts,e.id
      """, [.integer(start), .integer(last.1), .integer(last.1), .integer(last.0)]) { row in
      let time = try row.int("ts")
      memory.expire(at: time)
      var selected = try row.optionalText("novel_text") ?? row.text("text")
      if try row.int("evidence_id") > 0 && row.optionalText("novel_text") == nil {
        selected = Redaction.apply(ScreenLines.select(maskedText: try row.optionalText("content") ?? row.text("text"), knownKeys: memory.keys).lines.joined(separator: "\n")).text
        try connection.collectionWrite("UPDATE screen_payloads SET novel_text=? WHERE evidence_id=? AND novel_text IS NULL", [.maskedText(selected), .integer(try row.int("id"))])
      }
      memory.add(Set(selected.components(separatedBy: .newlines).filter { !$0.isEmpty }.map(ScreenLineKey.fromMaskedLine)), storedAt: time, now: time)
    }
  }
  func insertAdmittedInputEvents(_ events: [InputObservation], observationID: String, applicationIdentity: String?, record: CollectionRecord) throws {
    let groups = Dictionary(grouping: events) { Int(floor($0.timestamp)) }
    for second in groups.keys.sorted() {
      let bytes = CompactInput.encode(groups[second]!)
      var storedIdentity = applicationIdentity
      var existed = false
      try connection.namedRows("SELECT id,observation_id,ts,events,application_identity FROM input_batches WHERE observation_id=? AND ts=?",
        [.key(observationID), .integer(second)]) { row in
        existed = true
        storedIdentity = try row.optionalText("application_identity")
        guard record.matchesStoredIdentity(storedIdentity, incoming: applicationIdentity),
          case .integer = try row.value("id"), case .text = try row.value("observation_id"),
          case .integer = try row.value("ts"), case .blob(let storedBytes) = try row.value("events"), storedBytes == bytes else {
          throw CollectionReplayFailure()
        }
      }
      // INSERT OR IGNORE cannot reassign historical ownership. The final typed
      // baseline also catches side effects from triggers on an ignored insert.
      try connection.collectionWrite("INSERT OR IGNORE INTO input_batches(observation_id,ts,events,application_identity) VALUES(?,?,?,?)",
        [.key(observationID), .integer(second), .blob(bytes), applicationIdentity.map(SQLValue.key) ?? .null])
      let insertedID: SQLValue = !existed && sqlite3_changes(connection.handle) == 1 ? .integer(Int(sqlite3_last_insert_rowid(connection.handle))) : .null
      try connection.proveCollectionRows("input:" + observationID, adding:
        "SELECT * FROM input_batches WHERE observation_id=? AND (? IS NULL OR id=?) AND typeof(id)='integer' AND typeof(observation_id)='text' AND typeof(ts)='integer' AND ts=? AND typeof(events)='blob' AND events=? AND application_identity IS ?",
        [.key(observationID), insertedID, insertedID, .integer(second), .blob(bytes), storedIdentity.map(SQLValue.key) ?? .null], verifySet: false)
    }
    try connection.verifyCollectionRows("input:" + observationID)
  }

  public func inputEvents(in range: TimeRange) throws -> [InputObservation] {
    try locked {
      var result: [InputObservation] = []
      try connection.namedRows("SELECT events FROM input_batches WHERE ts>=? AND ts<? ORDER BY ts,id",
        [.integer(range.start), .integer(range.end)]) { result += try CompactInput.decode($0.data("events")) }
      return result
    }
  }
  func collectionSecond(_ time: Double) throws -> Int {
    try validatedCollectionSecond(time)
  }
  func storeCollectionBlob(_ text: String, at time: Int) throws -> String {
    let hash = probeHash(text)
    let identity = "blob:" + hash
    // Normally captured for all prepared hashes before the first write. This also
    // handles the same content serving as both text and structured payload.
    guard connection.collectionMaintenanceProof != nil || connection.collectionRowContracts[identity] != nil else { throw StorageError("Missing blob baseline") }
    let existed = try connection.integer("SELECT count(*) FROM collection_blobs WHERE hash=?", [.key(hash)]) > 0
    try connection.collectionWrite("INSERT OR IGNORE INTO collection_blobs(hash,content,created_ts) VALUES(?,?,?)",
      [.key(hash), .maskedText(text), .integer(time)])
    if existed {
      try connection.verifyCollectionRows(identity)
      guard try connection.integer("SELECT count(*) FROM collection_blobs WHERE hash=? AND typeof(hash)='text' AND typeof(content)='text' AND content=? AND typeof(created_ts)='integer'", [.key(hash), .maskedText(text)]) == 1 else {
        throw StorageError("Preexisting collection blob differs from prepared content")
      }
    }
    else {
      try connection.proveCollectionRows(identity, adding:
        "SELECT * FROM collection_blobs WHERE hash=? AND typeof(hash)='text' AND typeof(content)='text' AND content=? AND typeof(created_ts)='integer' AND created_ts=?",
        [.key(hash), .maskedText(text), .integer(time)])
    }
    return hash
  }
}

extension ActivityStorage {
  struct CollectionErasureTarget {
    let row: Int
    let identity: String?
    let time: Int
  }
  func collectionPayloadIDs(in range: TimeRange) throws -> [CollectionErasureTarget] {
    var result: [CollectionErasureTarget] = []
    try connection.namedRows("""
      SELECT p.evidence_id,p.occurrence_id,e.ts FROM screen_payloads p
      JOIN evidence e ON e.id=p.evidence_id WHERE e.ts>=? AND e.ts<?
      """, [.integer(range.start), .integer(range.end)]) {
      result.append(CollectionErasureTarget(row: try $0.int("evidence_id"), identity: try $0.optionalText("occurrence_id"), time: try $0.int("ts")))
    }
    return result
  }
  func verifyCollectionErasure(ids: [CollectionErasureTarget], observationIDs: [CollectionErasureTarget] = []) throws {
    try connection.requireCollectionMaintenance()
    // A collector may reuse the last erased SQLite rowid during a gap. The
    // original logical identity/clock, rather than its numeric slot, must be gone.
    for target in observationIDs {
      guard try connection.integer("SELECT count(*) FROM sample_observations WHERE id=? AND observation_id IS ? AND ts=?",
        [.integer(target.row), target.identity.map(SQLValue.key) ?? .null, .integer(target.time)]) == 0 else { throw StorageError("Deleted observation remains") }
    }
    for target in ids {
      guard try connection.integer("""
        SELECT count(*) FROM screen_payloads p LEFT JOIN evidence e ON e.id=p.evidence_id
        WHERE p.evidence_id=? AND p.occurrence_id IS ? AND (e.ts=? OR e.id IS NULL)
        """, [.integer(target.row), target.identity.map(SQLValue.key) ?? .null, .integer(target.time)]) == 0 else {
        throw StorageError("Deleted screen payload remains")
      }
    }
    try connection.collectionMaintenanceProof?.cleanupErasedReferences(connection)
  }
}
