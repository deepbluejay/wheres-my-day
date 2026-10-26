import Core
import Foundation
import SQLite3

/// A transaction snapshot judges each component by its own clock. All collection
/// entry points use this policy again at commit; publication is never permission.
struct CollectionAdmission {
  var record: CollectionRecord
  var refusals: [String: Int] = [:]
  var hasWork: Bool {
    if let observation = record.observation {
      return record.eventsOnly != true || observation.sample.observedAt != nil
        || (record.observationEvents?.count ?? 0) > CompactInput.encode([]).count
    }
    return record.eventsOnly != true || record.metadataObservedAt != nil
  }
}

extension ActivityStorage {
  func collectionRefusal(at time: Int, current: StorageSettings? = nil) throws -> String? {
    guard time < Int.max else { throw StorageError("Invalid collection time") }
    let current = try current ?? settings()
    if !current.recordingEnabled { return "recording_off" }
    if (current.pausedUntil ?? Int.min) > Int(Date().timeIntervalSince1970) { return "recording_paused" }
    if try forgotten(TimeRange(time, time + 1)) { return "forgotten" }
    let cutoff = try connection.integer("SELECT COALESCE(MAX(screen_cutoff),-9223372036854775808) FROM collection_retention")
    if time < cutoff { return "retention" }
    if try !logRecordingAllowed(at: time) { return "historical_off_or_pause" }
    return nil
  }
  func collectionAppRefusal(_ source: String, identity: String? = nil, current: StorageSettings) -> String? {
    if source.lowercased() == ownBundleID || identity == ApplicationPrivacyIdentity.digest(ownBundleID) { return "own_app" }
    if let identity {
      if current.excludesApplication(source, identity: identity) { return "excluded_app" }
    } else if HistoricalApplicationPrivacy(applications: current.excludedApps + [ownBundleID]).contains(source) {
      return "excluded_app"
    }
    // Old ready files cannot reconstruct an identity already replaced by a mask.
    // Refuse that ambiguous application explicitly rather than bypass exclusions.
    if identity == nil && source.contains("[") { return "application_identity_unavailable" }
    return nil
  }
  private func storedCollectionAppRefusal(_ record: CollectionRecord, inputSecond: Int? = nil,
    incomingIdentity: String?, current: StorageSettings) throws -> String? {
    // Publication admits the incoming acquisition. Only the writer's replay
    // snapshot can judge and account for an already committed component.
    guard connection.collectionMaintenanceProof != nil else { return nil }
    let identity = record.observation?.id ?? record.occurrenceID!
    let sql: String, values: [SQLValue]
    if let inputSecond {
      sql = "SELECT application_identity,NULL AS source FROM input_batches WHERE observation_id=? AND ts=?"
      values = [.key(identity), .integer(inputSecond)]
    } else {
      sql = "SELECT application_identity,source FROM collection_metadata WHERE identity=?"
      values = [.key(identity)]
    }
    var reason: String?
    try connection.namedRows(sql, values) { row in
      let stored = try row.optionalText("application_identity")
      guard record.matchesStoredIdentity(stored, incoming: incomingIdentity) else { throw CollectionReplayFailure() }
      if inputSecond != nil && stored == nil {
        // Historical batches have no label either. Another record, including
        // their incoming envelope, cannot supply their missing ownership.
        reason = "application_identity_unavailable"
      } else {
        reason = collectionAppRefusal(try row.text("source"), identity: stored, current: current)
      }
    }
    return reason
  }
  func admitCollection(_ original: CollectionRecord, refusing range: TimeRange? = nil) throws -> CollectionAdmission {
    try original.validate()
    var result = CollectionAdmission(record: original)
    // Freeze the old format before redaction fills fields introduced later.
    result.record.storageVersion = original.replayStorageVersion
    if original.screen != nil && original.occurrenceID == nil {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      result.record.occurrenceID = "legacy-" + probeHash(String(decoding: try encoder.encode(original), as: UTF8.self))
    }
    let current = try settings()
    func refuse(_ component: String, _ reason: String, count: Int = 1) {
      result.refusals[component + "_" + reason, default: 0] += count
    }
    func refusal(at second: Int) throws -> String? {
      if let reason = try collectionRefusal(at: second, current: current) { return reason }
      if let range, second >= range.start && second < range.end { return "privacy_erasure" }
      return nil
    }
    let parentReason = try refusal(at: original.time)
    if original.eventsOnly != true, let parentReason {
      refuse(original.observation != nil ? "container" : "capture", parentReason)
      result.record.eventsOnly = true
    }
    if var observation = original.observation {
      let appReason = observation.sample.excluded ? "excluded_at_acquisition" : collectionAppRefusal(observation.sample.bundleID, identity: observation.applicationPrivacyIdentity, current: current)
      let events = try original.observationEvents.map(CompactInput.decode) ?? observation.sample.inputEvents
      var reasons: [Int: String] = [:], permittedSeconds = Set<Int>()
      var allowed: [InputObservation] = []
      for event in events {
        let second = try collectionSecond(event.timestamp)
        let reason: String?
        if let appReason { reason = appReason }
        else if permittedSeconds.contains(second) { reason = nil }
        else if let cached = reasons[second] { reason = cached }
        else {
          reason = try storedCollectionAppRefusal(result.record, inputSecond: second,
            incomingIdentity: observation.applicationPrivacyIdentity, current: current) ?? refusal(at: second)
        }
        if let reason { reasons[second] = reason }
        else { permittedSeconds.insert(second); allowed.append(event) }
      }
      // Counts are batches (event-seconds), not guessed container ownership.
      if let appReason {
        for second in Set(events.map { Int(floor($0.timestamp)) }) { reasons[second] = appReason }
      }
      for reason in reasons.values { refuse("input_batch", reason) }
      if let observed = observation.sample.observedAt {
        if let reason = try appReason ?? storedCollectionAppRefusal(result.record,
          incomingIdentity: observation.applicationPrivacyIdentity, current: current) ?? refusal(at: collectionSecond(observed)) {
          refuse("metadata", reason); observation.sample.clearMetadata()
        }
      } else if result.record.eventsOnly == true {
        observation.sample.clearMetadata()
      }
      if let appReason {
        refuse("rich_context", appReason); observation.sample.excluded = true
      }
      observation.sample.inputEvents = []
      if result.record.eventsOnly == true { observation.sample.clearCollectionActivity() }
      result.record.observation = observation.redacted()
      result.record.observationEvents = CompactInput.encode(allowed)
    } else if var payload = original.screen {
      if let reason = collectionAppRefusal(original.source, identity: original.applicationPrivacyIdentity, current: current) {
        if original.eventsOnly != true && parentReason == nil { refuse("capture", reason) }
        result.record.eventsOnly = true
        if original.metadataObservedAt != nil || !original.documentKey.isEmpty || payload.document != nil || payload.browserAddress != nil { refuse("metadata", reason) }
        result.record.metadataObservedAt = nil
        payload.document = nil; payload.browserAddress = nil; result.record.documentKey = ""
      } else {
        let metadataTime = original.metadataObservedAt ?? ((!original.documentKey.isEmpty || payload.document != nil || payload.browserAddress != nil) ? Double(original.time) : nil)
        result.record.metadataObservedAt = metadataTime
        if let observed = metadataTime, let reason = try storedCollectionAppRefusal(result.record,
          incomingIdentity: original.applicationPrivacyIdentity, current: current) ?? refusal(at: collectionSecond(observed)) {
          refuse("metadata", reason); payload.document = nil; payload.browserAddress = nil
          result.record.documentKey = ""; result.record.metadataObservedAt = nil
        }
      }
      if result.record.eventsOnly == true { payload.text = ""; payload.observations = []; payload.blockHypotheses = nil; payload.languages = []; payload.engine = "unknown"; payload.languageStatus = "unavailable"; payload.window = nil }
      result.record.screen = payload
      result.record.screenJSON = try screenPayloadJSON(payload)
    }
    return result
  }
  func prepareCollectionTransaction(_ records: [CollectionRecord]) throws -> [CollectionAdmission] {
    let admissions = try records.map { try admitCollection($0) }
    // All identities, including later records, are read before refusal accounting
    // or any parent/child insertion can run a write or trigger.
    for admission in admissions { try baselineCollectionComponents(admission.record) }
    if connection.collectionRefusalExpected == nil {
      var expected: [String: Int] = [:]
      try connection.namedRows("SELECT reason,count FROM collection_policy_refusals") { row in
        guard case .text(let reason) = try row.value("reason"),
          case .integer(let count) = try row.value("count") else { throw StorageError("Invalid refusal counter") }
        expected[reason] = count
      }
      connection.collectionRefusalExpected = expected
      connection.collectionProofs["refusals"] = { [unowned self] in try self.verifyCollectionRefusals(self.connection.collectionRefusalExpected!) }
    }
    return admissions
  }
  func withCollectionAdmission<T>(_ original: CollectionRecord, _ write: (CollectionRecord) throws -> T) throws -> T {
    try writeCollectionAdmission(prepareCollectionTransaction([original])[0], write)
  }
  func writeCollectionAdmission<T>(_ admission: CollectionAdmission, _ write: (CollectionRecord) throws -> T) throws -> T {
    let expected = try countCollectionRefusals(admission.refusals)
    let result = try write(admission.record)
    try verifyCollectionRefusals(expected)
    return result
  }
  private func verifyCollectionRefusals(_ expected: [String: Int]) throws {
    guard try connection.integer("SELECT count(*) FROM collection_policy_refusals") == expected.count else { throw StorageError("Unexpected policy refusal") }
    for (reason, count) in expected {
      guard try connection.integer("SELECT count(*) FROM collection_policy_refusals WHERE reason=? AND typeof(reason)='text' AND typeof(count)='integer' AND count=?", [.key(reason), .integer(count)]) == 1 else { throw StorageError("Policy refusal was not counted") }
    }
  }
  private func countCollectionRefusals(_ refusals: [String: Int]) throws -> [String: Int] {
    // Privacy preservation also inserts independent metadata without a collection
    // envelope, so initialize its counter baseline before its first write.
    if connection.collectionRefusalExpected == nil { _ = try prepareCollectionTransaction([]) }
    try verifyCollectionRefusals(connection.collectionRefusalExpected!)
    var expected = connection.collectionRefusalExpected!
    for (reason, count) in refusals {
      expected[reason, default: 0] += count
      try connection.collectionWrite("INSERT INTO collection_policy_refusals(reason,count) VALUES(?,?) ON CONFLICT(reason) DO UPDATE SET count=count+excluded.count", [.key(reason), .integer(count)])
    }
    try verifyCollectionRefusals(expected)
    connection.collectionRefusalExpected = expected
    return expected
  }

  /// Refused parents can still carry independently permitted metadata. This local
  /// relation is deliberately absent from summary/query/model compatibility reads.
  func insertIndependentMetadata(_ record: CollectionRecord) throws {
    let time: Double?, identity: String, payload: String
    let source = record.observation?.sample.bundleID ?? record.source
    let appIdentity = record.observation?.applicationPrivacyIdentity ?? record.applicationPrivacyIdentity
    let documentKey = record.observation?.sample.documentKey ?? record.documentKey
    if var observation = record.observation {
      time = observation.sample.observedAt; identity = observation.id
      guard let time else { return }
      observation.sample.ts = try collectionSecond(time)
      observation.sample.inputEvents = []; observation.sample.clearCollectionActivity()
      payload = try record.observationJSON(observation)
    } else {
      time = record.metadataObservedAt; identity = record.occurrenceID!
      guard time != nil else { return }
      payload = try screenPayloadJSON(record.screen!)
    }
    let second = try collectionSecond(time!)
    try connection.baselineCollectionRows("metadata:" + identity, "SELECT * FROM collection_metadata WHERE identity=? ORDER BY id", [.key(identity)])
    var storedIdentity = appIdentity
    var existed = false
    try connection.namedRows("SELECT id,identity,ts,source,document_key,payload,application_identity FROM collection_metadata WHERE identity=?", [.key(identity)]) { row in
      existed = true
      storedIdentity = try row.optionalText("application_identity")
      guard record.matchesStoredIdentity(storedIdentity, incoming: appIdentity),
        case .integer = try row.value("id"), case .text = try row.value("identity"),
        case .integer(let storedSecond) = try row.value("ts"), storedSecond == second,
        case .text(let storedSource) = try row.value("source"), storedSource == source,
        case .text(let storedKey) = try row.value("document_key"), storedKey == documentKey,
        case .text(let storedPayload) = try row.value("payload"), storedPayload == payload else { throw CollectionReplayFailure() }
    }
    try connection.collectionWrite("INSERT OR IGNORE INTO collection_metadata(identity,ts,source,document_key,payload,application_identity) VALUES(?,?,?,?,?,?)", [.key(identity), .integer(second), .key(source), .maskedText(documentKey), .maskedText(payload), appIdentity.map(SQLValue.key) ?? .null])
    let insertedID: SQLValue = !existed && sqlite3_changes(connection.handle) == 1 ? .integer(Int(sqlite3_last_insert_rowid(connection.handle))) : .null
    try connection.proveCollectionRows("metadata:" + identity, adding:
      "SELECT * FROM collection_metadata WHERE identity=? AND (? IS NULL OR id=?) AND typeof(id)='integer' AND typeof(identity)='text' AND typeof(ts)='integer' AND ts=? AND typeof(source)='text' AND source=? AND typeof(document_key)='text' AND document_key=? AND typeof(payload)='text' AND payload=? AND application_identity IS ?",
      [.key(identity), insertedID, insertedID, .integer(second), .key(source), .maskedText(documentKey), .maskedText(payload), storedIdentity.map(SQLValue.key) ?? .null])
  }
}

extension ActivityStorage {
  /// Before erasing a parent, retain only metadata whose own second is outside
  /// the erasure. Independent input already lives outside the parent relation.
  func preserveCollectionMetadata(in range: TimeRange) throws {
    try connection.requireCollectionMaintenance()
    let bounds: [SQLValue] = [.integer(range.start), .integer(range.end)]
    // Read identities only, and finish the source SELECT before a unit can yield.
    // Re-read its content and judge policy after that unit enters its transaction.
    for screen in [false, true] {
      var afterTime = range.start, afterID = Int.min
      while true {
        var batch: [(Int, Int)] = []
        let source = screen ? "evidence o JOIN screen_payloads p ON p.evidence_id=o.id" : "sample_observations o"
        let clock = screen ? "p.metadata_ts" : "o.observed_ts"
        try connection.namedRows("""
          SELECT o.id,o.ts FROM \(source) WHERE o.ts>=?3 AND o.ts<?2
            AND \(clock) IS NOT NULL AND (\(clock)<?1 OR \(clock)>=?2)
            AND (o.ts>?3 OR o.id>?4) ORDER BY o.ts,o.id LIMIT 32
          """, bounds + [.integer(afterTime), .integer(afterID)]) {
          batch.append((try $0.int("id"), try $0.int("ts")))
        }
        guard let last = batch.last else { break }
        for (id, _) in batch {
          try connection.withCollectionMaintenanceUnit {
            var record: CollectionRecord?
            if screen {
              var parent: DatabaseRow?
              try connection.namedRows("""
                SELECT e.ts,e.source,e.document_key,p.occurrence_id,p.metadata_time,p.metadata_ts,e.application_identity
                FROM evidence e JOIN screen_payloads p ON p.evidence_id=e.id WHERE e.id=?3
                  AND e.ts>=?1 AND e.ts<?2 AND (p.metadata_ts<?1 OR p.metadata_ts>=?2)
                """, bounds + [.integer(id)]) { parent = $0 }
              if let row = parent {
                guard let payload = try screenPayload(evidenceID: id) else { throw StorageError("Missing metadata payload") }
                record = CollectionRecord(screen: payload, time: try row.int("ts"), source: try row.text("source"),
                  documentKey: try row.text("document_key"), occurrenceID: try row.optionalText("occurrence_id"),
                  metadataObservedAt: try row.optionalText("metadata_time").flatMap(Double.init) ?? Double(row.int("metadata_ts")),
                  applicationPrivacyIdentity: try row.optionalText("application_identity"))
              }
            } else {
              var payload: String?
              try connection.namedRows("""
                SELECT payload FROM sample_observations WHERE id=?3 AND ts>=?1 AND ts<?2
                  AND (observed_ts<?1 OR observed_ts>=?2)
                """, bounds + [.integer(id)]) { payload = try $0.text("payload") }
              if let payload {
                let observation = try JSONDecoder().decode(ActivityObservation.self, from: Data(payload.utf8))
                record = CollectionRecord(observation: observation, time: observation.sample.ts)
              }
            }
            guard let record else { return }
            let admission = try admitCollection(record, refusing: range)
            let expected = try countCollectionRefusals(admission.refusals)
            try insertIndependentMetadata(admission.record)
            try verifyCollectionRefusals(expected)
          }
        }
        afterID = last.0; afterTime = last.1
      }
    }
  }
}

extension ActivityStorage {
  func scrubObservationMetadata(in range: TimeRange) throws -> Int {
    try connection.requireCollectionMaintenance()
    var count = 0
    try connection.run("CREATE TEMP TABLE IF NOT EXISTS collection_metadata_erasure_proof(id INTEGER PRIMARY KEY,hash TEXT NOT NULL)")
    try connection.collectionWrite("DELETE FROM collection_metadata_erasure_proof")
    // The privacy-plan barrier protects this selected-work manifest across yields;
    // batching avoids retaining a backlog of decoded observations.
    while true {
      var batch: [(Int, String)] = []
      try connection.namedRows("""
        SELECT id,payload FROM sample_observations WHERE legacy_timing=0
          AND observed_ts>=?1 AND observed_ts<?2 AND (ts<?1 OR ts>=?2) LIMIT 32
        """, [.integer(range.start), .integer(range.end)]) { row in
        var observation = try JSONDecoder().decode(ActivityObservation.self, from: Data(row.text("payload").utf8))
        observation.sample.clearMetadata()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        batch.append((try row.int("id"), String(decoding: try encoder.encode(observation), as: UTF8.self)))
      }
      if batch.isEmpty { break }
      for (id, payload) in batch {
        try connection.collectionWrite("UPDATE sample_observations SET payload=?,observed_ts=NULL WHERE id=?", [.maskedText(payload), .integer(id)])
      }
      try verifyObservationMetadata(batch)
      for (id, payload) in batch {
        let hash = probeHash(payload)
        try connection.collectionWrite("INSERT INTO collection_metadata_erasure_proof VALUES(?,?)", [.integer(id), .key(hash)])
        guard try connection.integer("SELECT count(*) FROM collection_metadata_erasure_proof WHERE id=? AND hash=?", [.integer(id), .key(hash)]) == 1 else { throw StorageError("Observation erasure proof was not stored") }
      }
      count += batch.count
    }
    return count
  }
  func verifyScrubbedObservationMetadata(count: Int) throws {
    guard try connection.integer("SELECT count(*) FROM collection_metadata_erasure_proof") == count else { throw StorageError("Observation erasure proof differs") }
    try connection.namedRows("SELECT id,hash FROM collection_metadata_erasure_proof") { row in
      try verifyObservationMetadata([(try row.int("id"), try row.text("hash"))], hashed: true)
    }
    try connection.collectionWrite("DELETE FROM collection_metadata_erasure_proof")
  }
  func verifyObservationMetadata(_ expected: [(Int, String)], hashed: Bool = false) throws {
    for (id, payload) in expected {
      var verified = false
      try connection.namedRows("SELECT payload,observed_ts FROM sample_observations WHERE id=?", [.integer(id)]) { row in
        if case .null = try row.value("observed_ts") {
          verified = try (hashed ? probeHash(row.text("payload")) : row.text("payload")) == payload
        }
      }
      guard verified else { throw StorageError("Deleted observation metadata remains") }
    }
  }
}

private extension TimeSample {
  mutating func clearCollectionActivity() {
    keys = 0; clicks = 0; scrolls = 0; moved = false; synthetic = 0; keepingAwake = false
  }
}
