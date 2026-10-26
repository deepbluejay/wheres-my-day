import Core
import Darwin
import Foundation
import SQLite3

public final class ActivityStorage: SampleWriter, ObservationWriter, SampleReader, IntervalWriter, IntervalReader,
  EvidenceWriter, EvidenceReader, SettingsEditingStore, SettingsBackupActions, LogPositionStore, LogBatchWriter, ModelCallStore, RecordDeletion,
  EvidenceRetention, ScreenCaptureWriter, StructuredScreenCaptureWriter, AXProbeLinkedScreenWriter, ForgottenRangeReader, AgentLogStorage, ActivityQueryStorage
{
  public enum Role { case client, recorder }
  let connection: SQLiteConnection
  let lock = NSRecursiveLock()
  let url: URL
  let databaseScope: DatabaseOpenScope
  let ownBundleID: String
  let openedIdentity: [UInt64]?
  public let settingsIdentity: String
  let appDataDirectory: URL
  private let backupMarker: (URL) throws -> Void
  private var recorderLock: RecorderDatabaseLock?
  // These receipts belong to this storage instance only; reopening cannot recover an old worker.
  var collectionWriterFactory: (() throws -> ActivityStorage)?
  var collectionPublicationFault: ((String) throws -> Void)?
  var collectionPeakReadBytes = 0
  var collectionEnumerationVisits = 0
  var noveltyKeyReader: ((Int) throws -> [String: Int])?
  var axProbeLeases = Set<String>()
  var axProbeFinishes: [String: AXProbeFinish] = [:]
  var axProbePersistenceFailures: [String: AXProbeReceipt] = [:]
  var axProbeOverloadTotals: [String: Int] = [:]
  var axProbeOverloadAttempts: [String: String] = [:]
  public private(set) var securityHealth = StorageSecurityHealth()

  /// Explicit paths keep this adapter away from the running recorder's file.
  /// The expected app folder is separate so a DB override cannot exclude unrelated files.
  public init(url: URL, appDataDirectory: URL, role: Role = .client, busyMilliseconds: Int32? = nil,
    excludeFromBackup: @escaping (URL) throws -> Void = ActivityStorage.excludeFromBackup, readOnly: Bool = false, databaseScope: DatabaseOpenScope,
    recorderLock: RecorderDatabaseLock? = nil, ownBundleID: String = ActivityProbeIdentity.bundleID) throws {
    guard !ownBundleID.isEmpty else { throw StorageError("Own application identity is required") }
    self.ownBundleID = ownBundleID.lowercased()
    try databaseScope.validateAppDataPath(appDataDirectory)
    try databaseScope.validatePath(url)
    precondition(TestPathGuard.permits(appDataDirectory) && TestPathGuard.permits(url), "Tests must inject invented paths")
    self.databaseScope = databaseScope
    if let recorderLock {
      guard role == .recorder, !readOnly else { throw StorageError("Recorder lock requires recorder storage") }
      try recorderLock.validate(database: url)
    }
    self.url = url; self.appDataDirectory = appDataDirectory; self.backupMarker = excludeFromBackup
    let parent = url.deletingLastPathComponent()
    if readOnly {
      guard role == .client else { throw StorageError("Read-only recorder refused") }
    } else if try FileLocation.same(parent, appDataDirectory) {
      do { try excludeFromBackup(parent) }
      catch { securityHealth.backupExclusionFailure = .backupExclusionFailed }
    } else {
      securityHealth.backupExclusionFailure = .backupExclusionSkippedOverride
    }
    // The sample loop retries busy writes itself, so a recorder must not wait through later seconds.
    let wait = busyMilliseconds ?? (role == .recorder ? 0 : 3000)
    connection = try SQLiteConnection(url: url, readOnly: readOnly, scope: self.databaseScope, busyMilliseconds: wait)
    settingsIdentity = try FileLocation.key(url)
    var info = stat()
    openedIdentity = stat(url.path, &info) == 0 ? [UInt64(info.st_dev), UInt64(info.st_ino)] : nil
    if !readOnly {
      try connection.createSchema()
      // Recovery of a derived view is best effort; acquired content never depends on it.
      if (try? connection.integer("SELECT count(*) FROM screen_payloads WHERE novel_text IS NULL")) ?? 0 > 0 {
        _ = try? connection.transaction(collectionMaintenance: true) { try repairCollectionNovelty() }
      }
    }
    if role == .recorder {
      self.recorderLock = try recorderLock ?? RecorderDatabaseLock(database: url, scope: databaseScope)
      _ = connection.truncateWAL()
    }
  }
  public func retryBackupExclusion() -> StorageSecurityHealth {
    locked {
      guard (try? FileLocation.same(url.deletingLastPathComponent(), appDataDirectory)) == true else {
        return StorageSecurityHealth(backupExclusionFailure: .backupExclusionSkippedOverride)
      }
      do { try backupMarker(appDataDirectory); securityHealth.backupExclusionFailure = nil }
      catch { securityHealth.backupExclusionFailure = .backupExclusionFailed }
      return securityHealth
    }
  }
  public static func excludeFromBackup(_ directory: URL) throws {
    var directory = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
  }
  func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
  public func withQuerySnapshot<T>(_ body: () throws -> T) throws -> T {
    try locked { try connection.transaction(write: false, body) }
  }
  func forgotten(_ range: TimeRange) throws -> Bool {
    try connection.integer(
      "SELECT count(*) FROM forgotten_ranges WHERE start_ts<? AND end_ts>?",
      [.integer(range.end), .integer(range.start)]) > 0
  }
  @discardableResult func insertSample(_ observed: TimeSample, legacy: Bool = false) throws -> Bool {
    var sample = observed
    if !legacy && sample.applicationPrivacyIdentity == nil {
      sample.applicationPrivacyIdentity = ApplicationPrivacyIdentity.originalDigest(sample.bundleID)
    }
    if let observedAt = sample.observedAt {
      let second = try collectionSecond(observedAt)
      if try collectionRefusal(at: second) != nil { sample.clearMetadata() }
    }
    if !sample.inputEvents.isEmpty {
      var human = InputCounts()
      for event in try permittedInputEvents(sample.inputEvents) where event.programMade == false { human.observe(event) }
      sample.keys = human.keys; sample.clicks = human.clicks; sample.scrolls = human.scrolls; sample.moved = human.moved
    }
    guard sample.ts < Int.max else { throw StorageError("Timestamp outside supported range") }
    guard try (legacy ? !forgotten(TimeRange(sample.ts, sample.ts + 1)) : collectionRefusal(at: sample.ts) == nil) else { return false }
    if collectionAppRefusal(sample.bundleID, identity: sample.applicationPrivacyIdentity, current: try settings()) != nil { sample.excluded = true; sample.clearMetadata() }
    if try !legacy && connection.integer("SELECT count(*) FROM samples WHERE ts=?", [.integer(sample.ts)]) > 0 {
      return false
    }
    try connection.collectionWrite(
      """
      INSERT INTO samples(ts,bundle_id,app,window,document_key,keys,clicks,scrolls,
        moved,synthetic,keeping_awake,excluded,observed_ts,application_identity)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      """,
      [
        .integer(sample.ts), .key(sample.bundleID), .text(sample.app), .text(sample.excluded ? "" : sample.window),
        .text(sample.excluded ? "" : sample.documentKey),
        .integer(sample.keys), .integer(sample.clicks), .integer(sample.scrolls), .integer(sample.moved ? 1 : 0),
        .integer(sample.synthetic), .integer(sample.keepingAwake ? 1 : 0), .integer(sample.excluded ? 1 : 0),
        sample.observedAt.map { .integer(Int(floor($0))) } ?? .null,
        sample.applicationPrivacyIdentity.map(SQLValue.key) ?? .null,
      ])
    return true
  }
  @discardableResult public func appendSamples(_ samples: [TimeSample]) throws -> AppendResult {
    try locked { try connection.transaction {
      let admissions = try prepareCollectionTransaction(samples.map {
        let observation = ActivityObservation(sample: $0)
        return CollectionRecord(observation: observation, time: $0.ts, observationEvents: CompactInput.encode($0.inputEvents))
      })
      for admission in admissions { _ = try writeCollectionAdmission(admission) { try insertAdmittedObservation($0) } }
      return try append(samples, using: { try insertSample($0) })
    } }
  }
  public func samples(in range: TimeRange) throws -> [TimeSample] {
    try locked {
      let identity = try connection.integer("SELECT count(*) FROM pragma_table_info('samples') WHERE name='application_identity'") == 1
        ? "application_identity" : "NULL AS application_identity"
      var result: [TimeSample] = []
      try connection.namedRows(
        """
        SELECT ts, bundle_id, app, window, document_key, keys, clicks, scrolls, moved, synthetic,
        keeping_awake, excluded, \(identity) FROM samples WHERE ts>=? AND ts<? ORDER BY ts, id
        """,
        [.integer(range.start), .integer(range.end)]
      ) {
        var sample = TimeSample(
          ts: try $0.int("ts"), bundleID: try $0.text("bundle_id"), app: try $0.text("app"),
            window: try $0.text("window"), documentKey: try $0.text("document_key"),
            keys: try $0.int("keys"), clicks: try $0.int("clicks"), scrolls: try $0.int("scrolls"),
            moved: try $0.int("moved") != 0, synthetic: try $0.int("synthetic"),
            keepingAwake: try $0.int("keeping_awake") != 0, excluded: try $0.int("excluded") != 0)
        sample.applicationPrivacyIdentity = try $0.optionalText("application_identity")
        result.append(sample)
      }
      return result
    }
  }
  @discardableResult func insertInterval(_ interval: NamedInterval) throws -> Bool {
    guard try !forgotten(interval.range) else { return false }
    try connection.run(
      "INSERT INTO intervals(start_ts,end_ts,name,description,kind,project,state) VALUES(?,?,?,?,?,?,?)",
      [
        .integer(interval.range.start), .integer(interval.range.end), .text(interval.name),
        .text(interval.description),
        interval.kind.map { .text($0.rawValue) } ?? .null, .text(interval.project), .text(interval.state.rawValue),
      ])
    return true
  }
  @discardableResult public func appendIntervals(_ intervals: [NamedInterval]) throws -> AppendResult {
    try locked { try connection.transaction { try append(intervals, using: insertInterval) } }
  }
  public func intervals(in range: TimeRange) throws -> [NamedInterval] {
    try locked {
      var result: [NamedInterval] = []
      try connection.namedRows(
        """
        SELECT start_ts, end_ts, name, description, kind, project, state FROM intervals WHERE start_ts<? AND
        end_ts>? ORDER BY start_ts
        """,
        [.integer(range.end), .integer(range.start)]
      ) {
        result.append(
          NamedInterval(
            range: TimeRange(try $0.int("start_ts"), try $0.int("end_ts")),
            name: try $0.text("name"), description: try $0.text("description"),
            kind: try $0.optionalText("kind").flatMap(ActivityKind.init(rawValue:)), project: try $0.text("project"),
            state: IntervalState(rawValue: try $0.text("state"))!))
      }
      return result
    }
  }
  private func nativeClaudeID(_ row: EvidenceText) -> String? {
    guard row.kind == .prompt, let id = row.sourceID,
      id.hasPrefix("claude:"), !id.hasPrefix("claude:legacy:") else { return nil }
    return id
  }
  private func refuseIdentity(source: String, id: String) throws {
    try connection.run("INSERT OR IGNORE INTO forgotten_sources VALUES(?,?)",
      [.key(source), .key(id)])
  }
  private func refuseNativeIdentity(_ row: EvidenceText) throws {
    if let id = nativeClaudeID(row) { try refuseIdentity(source: row.source, id: id) }
  }
  private func nativeAliases(_ row: EvidenceText) -> [String] {
    guard nativeClaudeID(row) != nil else { return [] }
    return row.sourceAliases.filter {
      $0 != row.sourceID && $0.hasPrefix("claude:") && !$0.hasPrefix("claude:legacy:")
    }
  }
  private func consumeAliases(_ row: EvidenceText) throws {
    // A paired copy id is consumed forever, including when its canonical instruction is refused or deleted.
    // Reusing the refusal table needs no text, lineage, or alias lifecycle tied to retention.
    for alias in nativeAliases(row) { try refuseIdentity(source: row.source, id: alias) }
  }
  @discardableResult func insertEvidence(_ row: EvidenceText, alreadyMasked: Bool = false, applicationIdentity: String? = nil) throws -> Bool {
    let textValue: (String) -> SQLValue = alreadyMasked ? SQLValue.maskedText : SQLValue.text
    // A copy stored, deleted or refused under its own id names this same instruction. Checked before this row
    // consumes its own aliases, and the canonical id is remembered so a later read cannot store it either.
    for alias in nativeAliases(row)
    where try connection.integer("""
      SELECT EXISTS(SELECT 1 FROM evidence WHERE kind='prompt' AND source_id=?)
        OR EXISTS(SELECT 1 FROM forgotten_sources WHERE source_id=?)
      """, [.key(alias), .key(alias)]) > 0
    {
      try refuseNativeIdentity(row)
      try consumeAliases(row)
      return false
    }
    try consumeAliases(row)
    guard row.ts < Int.max else { throw StorageError("Timestamp outside supported range") }
    guard try !forgotten(TimeRange(row.ts, row.ts + 1)) else {
      try refuseNativeIdentity(row)
      return false
    }
    if let id = row.sourceID,
      try connection.integer(
        "SELECT count(*) FROM forgotten_sources WHERE source=? AND source_id=?",
        [.key(row.source), .key(id)]) > 0
    {
      return false
    }
    // Native Claude ids survive copied session history. Legacy fingerprints remain source-scoped.
    if let id = nativeClaudeID(row),
      try connection.integer("""
        SELECT EXISTS(SELECT 1 FROM evidence WHERE kind='prompt' AND source_id=?)
          OR EXISTS(SELECT 1 FROM forgotten_sources WHERE source_id=?)
        """, [.key(id), .key(id)]) > 0
    {
      return false
    }
    try connection.collectionWrite(
      """
      INSERT OR IGNORE INTO evidence(ts, kind, source, source_id, document_key, project, text, application_identity)
      VALUES(?,?,?,?,?,?,?,?)
      """,
      [
        .integer(row.ts), textValue(row.kind.rawValue), .key(row.source), row.sourceID.map(SQLValue.key) ?? .null,
        textValue(row.documentKey), textValue(row.project), textValue(row.text), applicationIdentity.map(SQLValue.key) ?? .null,
      ])
    return sqlite3_changes(connection.handle) == 1
  }
  private func maskEvidence(_ row: EvidenceText) -> EvidenceText {
    EvidenceText(
      ts: row.ts, kind: row.kind, source: Redaction.applyKnownSecrets(row.source).text,
      sourceID: row.sourceID.map { Redaction.applyKnownSecrets($0).text },
      sourceAliases: row.sourceAliases.map { Redaction.applyKnownSecrets($0).text },
      documentKey: Redaction.apply(row.documentKey).text, project: Redaction.apply(row.project).text,
      text: Redaction.apply(row.text).text)
  }
  @discardableResult public func appendEvidence(_ evidence: [EvidenceText]) throws -> AppendResult {
    let prepared = evidence.map(maskEvidence)
    return try locked {
      try connection.transaction {
        try append(prepared, using: { $0.kind == .screen ? false : try insertEvidence($0, alreadyMasked: true) })
      }
    }
  }
  @discardableResult public func appendScreenCapture(
    text: String, at time: Int, source: String, documentKey: String = "", project: String = "",
    knownKeys: Set<String>
  ) throws -> ScreenCaptureResult {
    try storeScreenCapture(text: text, at: time, source: source, documentKey: documentKey,
      project: project, knownKeys: knownKeys, probe: nil)
  }
  @discardableResult public func appendScreenCapture(
    text: String, at time: Int, source: String, documentKey: String = "", project: String = "",
    knownKeys: Set<String>, probe: AXProbeLink
  ) throws -> ScreenCaptureResult {
    try storeScreenCapture(text: text, at: time, source: source, documentKey: documentKey,
      project: project, knownKeys: knownKeys, probe: probe)
  }
  func storeScreenCapture(text: String, at time: Int, source: String, documentKey: String,
    project: String, knownKeys: Set<String>, probe: AXProbeLink?, payload: ScreenTextPayload? = nil, preparedJSON: String? = nil, occurrenceID: String? = nil, metadataObservedAt: Double? = nil) throws -> ScreenCaptureResult {
    let value = preparedJSON != nil ? payload! : (payload ?? ScreenTextPayload(text: text)).redacted()
    let record = CollectionRecord(screen: value, time: time, source: Redaction.applyKnownSecrets(source).text,
      documentKey: Redaction.apply(documentKey).text, screenJSON: try screenPayloadJSON(value),
      occurrenceID: occurrenceID ?? UUID().uuidString, metadataObservedAt: metadataObservedAt,
      applicationPrivacyIdentity: ApplicationPrivacyIdentity.originalDigest(source))
    return try locked {
      repairPendingCollectionNovelty()
      return try connection.transaction {
        try withCollectionAdmission(record) { allowed in
          if allowed.eventsOnly == true {
            try insertIndependentMetadata(allowed)
            return ScreenCaptureResult(append: AppendResult(refused: 1), addedKeys: [])
          }
          return try insertAdmittedScreen(allowed, project: project, probe: probe)
        }
      }
    }
  }
  func insertAdmittedScreen(_ record: CollectionRecord, project: String, probe: AXProbeLink?) throws -> ScreenCaptureResult {
    let preparedPayload = record.screen!, masked = preparedPayload.text
    let payloadJSON = try record.screenJSON ?? screenPayloadJSON(preparedPayload)
    let time = record.time, source = record.source, occurrenceID = record.occurrenceID
    let metadataTime = record.metadataObservedAt
    let row = EvidenceText(ts: time, kind: .screen, source: source,
      documentKey: record.documentKey, project: Redaction.apply(project).text, text: masked)
    if let occurrenceID {
      var existing: Int?
      try connection.namedRows("""
        SELECT e.id,e.ts,e.source,e.document_key,t.content AS text,b.content AS payload,p.metadata_time,p.metadata_ts,e.application_identity
        FROM screen_payloads p JOIN evidence e ON e.id=p.evidence_id
        JOIN collection_blobs t ON t.hash=p.text_hash JOIN collection_blobs b ON b.hash=p.payload_hash
        WHERE p.occurrence_id=?
        """, [.key(occurrenceID)]) { stored in
        guard case .integer(let second) = try stored.value("ts") else { throw StorageError("Screen occurrence time differs") }
        let storedPayload = try JSONDecoder().decode(ScreenTextPayload.self, from: Data(stored.text("payload").utf8))
        let storedMetadataTime = try stored.optionalText("metadata_time").flatMap(Double.init)
        if let metadata = storedMetadataTime {
          guard case .integer(let metadataSecond) = try stored.value("metadata_ts"),
            metadataSecond == (try collectionSecond(metadata)) else { throw StorageError("Screen metadata time differs") }
        } else {
          guard case .null = try stored.value("metadata_ts"), case .null = try stored.value("metadata_time") else { throw StorageError("Screen metadata time differs") }
        }
        let projected = try admitCollection(CollectionRecord(screen: storedPayload, time: second,
          source: stored.text("source"), documentKey: stored.text("document_key"), occurrenceID: occurrenceID,
          metadataObservedAt: storedMetadataTime, applicationPrivacyIdentity: stored.optionalText("application_identity"))).record
        guard record.matchesStoredIdentity(try stored.optionalText("application_identity"), incoming: record.applicationPrivacyIdentity), second == time, try stored.text("source") == source, try stored.text("text") == masked,
          projected.screen == preparedPayload, projected.documentKey == record.documentKey,
          projected.metadataObservedAt == metadataTime else { throw CollectionReplayFailure() }
        existing = try stored.int("id")
      }
      if let existing {
        try connection.verifyCollectionRows("screen:" + occurrenceID)
        return ScreenCaptureResult(append: AppendResult(), addedKeys: [], evidenceID: existing)
      }
      guard try connection.integer("SELECT count(*) FROM screen_payloads WHERE occurrence_id=?", [.key(occurrenceID)]) == 0 else { throw StorageError("Incomplete screen occurrence") }
    }
    // Failure rebuilding the compatibility keys must never gate acquired content.
    let keys: [String: Int]
    var rebuildFailed = false
    do { keys = try noveltyKeyReader?(time) ?? recentScreenLineKeys(at: time) }
    catch { keys = [:]; rebuildFailed = true }
    let selected = ScreenLines.select(maskedText: masked, knownKeys: Set(keys.keys))
    let selectedText = Redaction.apply(selected.lines.joined(separator: "\n")).text
    var reference = row; reference.text = ""
    let stored = try insertEvidence(reference, alreadyMasked: true, applicationIdentity: record.applicationPrivacyIdentity)
    guard stored else { throw StorageError("Permitted screen occurrence was not stored") }
    let evidenceID = stored ? Int(sqlite3_last_insert_rowid(connection.handle)) : nil
    if let evidenceID {
      let textHash = try storeCollectionBlob(masked, at: time)
      let payloadHash = try storeCollectionBlob(payloadJSON, at: time)
      try connection.collectionWrite("INSERT INTO screen_payloads(evidence_id,payload,text_hash,payload_hash,novel_text,novelty_rebuild_failed,occurrence_id,metadata_ts,metadata_time) VALUES(?,'',?,?,?,?,?,?,?)",
        [.integer(evidenceID), .key(textHash), .key(payloadHash), rebuildFailed ? .null : .maskedText(selectedText), .integer(rebuildFailed ? 1 : 0), occurrenceID.map(SQLValue.key) ?? .null, try metadataTime.map { .integer(try collectionSecond($0)) } ?? .null,
          metadataTime.map { .maskedText(String($0)) } ?? .null])
      try connection.proveCollectionRows("screen:" + occurrenceID!, adding: """
        SELECT p.*,e.*,t.hash,t.content,t.created_ts,b.hash,b.content,b.created_ts FROM screen_payloads p
        JOIN collection_blobs t ON t.hash=p.text_hash JOIN collection_blobs b ON b.hash=p.payload_hash
        JOIN evidence e ON e.id=p.evidence_id
        WHERE p.evidence_id=? AND p.text_hash=? AND p.payload_hash=? AND p.occurrence_id IS ?
          AND p.metadata_ts IS ? AND p.metadata_time IS ? AND p.novel_text IS ?
          AND t.content=? AND b.content=? AND typeof(e.ts)='integer' AND e.ts=?
          AND e.source=? AND e.document_key=? AND e.project=? AND e.kind='screen' AND e.text='' AND p.payload=''
          AND e.application_identity IS ? AND e.source_id IS NULL AND typeof(e.id)='integer' AND typeof(e.kind)='text'
          AND typeof(e.source)='text' AND typeof(e.document_key)='text' AND typeof(e.project)='text' AND typeof(e.text)='text'
          AND typeof(p.evidence_id)='integer' AND typeof(p.payload)='text' AND typeof(p.text_hash)='text'
          AND typeof(p.payload_hash)='text' AND typeof(p.occurrence_id)='text'
          AND (p.novel_text IS NULL OR typeof(p.novel_text)='text')
          AND (p.metadata_ts IS NULL OR typeof(p.metadata_ts)='integer')
          AND (p.metadata_time IS NULL OR typeof(p.metadata_time)='text')
          AND typeof(p.novelty_rebuild_failed)='integer' AND p.novelty_rebuild_failed=?
        """, [.integer(evidenceID), .key(textHash), .key(payloadHash), occurrenceID.map(SQLValue.key) ?? .null,
          try metadataTime.map { .integer(try collectionSecond($0)) } ?? .null,
          metadataTime.map { .maskedText(String($0)) } ?? .null,
          rebuildFailed ? .null : .maskedText(selectedText), .maskedText(masked), .maskedText(payloadJSON), .integer(time),
          .key(source), .maskedText(row.documentKey), .maskedText(row.project), record.applicationPrivacyIdentity.map(SQLValue.key) ?? .null, .integer(rebuildFailed ? 1 : 0)])
    }
    if let occurrenceID { try connection.verifyCollectionRows("screen:" + occurrenceID) }
    if let evidenceID, let probe {
      try connection.run("""
        UPDATE ax_probe_attempts SET evidence_id=? WHERE run_id=? AND attempt_id=? AND ts=?
          AND json_extract(payload,'$.ax.status') IN ('pending','watchdog')
        """, [.integer(evidenceID), .key(probe.runID), .key(probe.attemptID), .integer(time)])
    }
    return ScreenCaptureResult(
      append: stored ? AppendResult(stored: 1) : AppendResult(refused: 1),
      addedKeys: stored ? Set(row.text.components(separatedBy: .newlines).map(ScreenLineKey.fromMaskedLine)) : [],
      evidenceID: evidenceID)
  }
  public func deletionsSoFar() throws -> Int {
    try locked { try connection.integer("SELECT count(*) FROM forgotten_ranges") }
  }
  public func forgottenRanges(in range: TimeRange) throws -> [TimeRange] {
    try locked {
      var result: [TimeRange] = []
      try connection.namedRows(
        "SELECT start_ts,end_ts FROM forgotten_ranges WHERE start_ts<? AND end_ts>? ORDER BY start_ts,end_ts",
        [.integer(range.end), .integer(range.start)]
      ) { result.append(TimeRange(try $0.int("start_ts"), try $0.int("end_ts"))) }
      return result
    }
  }
  private func append<T>(_ rows: [T], using insert: (T) throws -> Bool) throws -> AppendResult {
    var result = AppendResult()
    for row in rows {
      if try insert(row) { result.stored += 1 } else { result.refused += 1 }
    }
    return result
  }
  public func evidence(in range: TimeRange) throws -> [EvidenceText] {
    try locked {
      var result: [EvidenceText] = []
      try connection.namedRows(
        """
        SELECT e.ts,e.kind,e.source,e.source_id,e.document_key,e.project,COALESCE(b.content,e.text) AS text
        FROM evidence e LEFT JOIN screen_payloads p ON p.evidence_id=e.id
        LEFT JOIN collection_blobs b ON b.hash=p.text_hash WHERE e.ts>=? AND e.ts<? ORDER BY e.ts,e.id
        """,
        [.integer(range.start), .integer(range.end)]
      ) {
        result.append(
          EvidenceText(
            ts: try $0.int("ts"), kind: EvidenceKind(rawValue: try $0.text("kind"))!,
            source: try $0.text("source"), sourceID: try $0.optionalText("source_id"),
            documentKey: try $0.text("document_key"),
            project: try $0.text("project"), text: try $0.text("text")))
      }
      return result
    }
  }
  public func recentScreenLineKeys(at now: Int) throws -> [String: Int] {
    try locked {
      var memory = ScreenKeyMemory()
      let start = now > Int.min + RecorderTiming.lineMemorySeconds ? now - RecorderTiming.lineMemorySeconds : Int.min
      for row in try novelEvidence(in: TimeRange(start, now == Int.max ? now : now + 1)) where row.kind == .screen {
        memory.add(Set(row.text.components(separatedBy: .newlines).filter { !$0.isEmpty }.map(ScreenLineKey.fromMaskedLine)), storedAt: row.ts, now: now)
      }
      memory.expire(at: now)
      return memory.storedAt
    }
  }
  public func logPosition(path: String) throws -> LogPosition? {
    try locked {
      var result: LogPosition?
      try connection.namedRows(
        "SELECT path,device,inode,offset,state,seen_ts FROM log_positions WHERE path=?", [.key(path)]
      ) {
        result = LogPosition(
          path: try $0.text("path"), device: try $0.int("device"), inode: try $0.int("inode"),
          offset: try $0.int("offset"), state: try $0.text("state"), seenAt: try $0.int("seen_ts"))
      }
      return result
    }
  }
  private func maskedLogState(_ text: String) throws -> String {
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      !Set(object.keys).isDisjoint(with: ["session", "threadID", "project", "folder", "queued", "metadataRead"])
    else { return Redaction.apply(text).text }
    var state = try AgentLogState.decode(text)
    state.project = Redaction.apply(state.project).text
    return Redaction.applyKnownSecrets(try state.encoded()).text
  }

  public func saveLogPosition(_ p: LogPosition) throws {
    try insertLogPosition(p, state: .maskedText(try maskedLogState(p.state)))
  }
  private func insertLogPosition(_ p: LogPosition, state: SQLValue) throws {
    try locked {
      try connection.run(
        """
        INSERT INTO log_positions(path,device,inode,offset,state,seen_ts) VALUES(?,?,?,?,?,?)
        ON CONFLICT(path) DO UPDATE SET device=excluded.device,inode=excluded.inode,
        offset=excluded.offset,state=excluded.state,seen_ts=excluded.seen_ts
        """,
        [.key(p.path), .integer(p.device), .integer(p.inode), .integer(p.offset), state, .integer(p.seenAt)])
    }
  }
  @discardableResult public func appendLogBatch(_ evidence: [EvidenceText], position: LogPosition) throws
    -> AppendResult
  {
    let prepared = evidence.map(maskEvidence)
    let state = SQLValue.maskedText(try maskedLogState(position.state))
    return try locked {
      try connection.transaction {
        let days = try settings().promptRetentionDays
        let (cutoff, overflow) = position.seenAt.subtractingReportingOverflow(days * 86400)
        let oldest = overflow ? Int.min : cutoff
        let result = try append(
          prepared,
          using: {
            guard $0.kind != .screen else { return false }
            // Privacy first: a prompt in a deleted range, a pause or off is remembered even when it is also too old.
            if try forgotten(TimeRange($0.ts, $0.ts + 1)) || !logRecordingAllowed(at: $0.ts) {
              try refuseNativeIdentity($0)
              try consumeAliases($0)
              return false
            }
            // Too old for retention: refused now, but not remembered, so a longer retention can take it later.
            if $0.ts < oldest { return false }
            return try insertEvidence($0, alreadyMasked: true)
          })
        try insertLogPosition(position, state: state)
        return result
      }
    }
  }
  func insertModelCall(_ c: ModelCall) throws {
    guard c.ts < Int.max else { throw StorageError("Timestamp outside supported range") }
    try connection.run(
      """
      INSERT INTO model_calls(ts, start_ts, end_ts, model, input_tokens, cached_tokens, output_tokens,
      succeeded, table_facts, pending, attempt_id) VALUES(?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(attempt_id) DO UPDATE SET pending=MIN(model_calls.pending,excluded.pending),
        succeeded=CASE WHEN model_calls.pending=1 THEN excluded.succeeded ELSE model_calls.succeeded END
      """,
      [
        .integer(c.ts), .integer(c.range.start), .integer(c.range.end), .text(c.model), .integer(c.inputTokens),
        .integer(c.cachedTokens), .integer(c.outputTokens), .integer(c.succeeded ? 1 : 0),
        // Fixed numeric/boolean facts contain no free text and must keep their JSON bytes.
        try c.tableFacts.map { .maskedText(String(decoding: try JSONEncoder().encode($0), as: UTF8.self)) } ?? .null,
        .integer(c.pending ? 1 : 0), c.attemptID.map { .maskedText($0) } ?? .null,
      ])
  }
  @discardableResult public func appendModelCall(_ c: ModelCall) throws -> AppendResult {
    try locked {
      guard sqlite3_db_readonly(connection.handle, "main") == 0 else { throw StorageError("Read-only accounting store") }
      let journal = try ModelCallJournal(database: url)
      return try journal.withAccountingLock {
        if c.attemptID != nil, try !forgottenRanges(in: c.range).isEmpty { return AppendResult(refused: 1) }
        try recoverModelCalls(from: journal)
        if c.attemptID != nil { try journal.save(c) }
        let result = try connection.transaction { try insertAccountedModelCall(c) }
        if c.attemptID != nil { try journal.clear() }
        return result
      }
    }
  }
  public func modelCalls(in range: TimeRange) throws -> [ModelCall] {
    try readModelCalls(where: "ts>=? AND ts<?", values: [.integer(range.start), .integer(range.end)])
  }
  public func modelCalls(overlapping range: TimeRange) throws -> [ModelCall] {
    guard range.start < range.end else { return [] }
    return try readModelCalls(where: "start_ts<? AND end_ts>?", values: [.integer(range.end), .integer(range.start)])
  }
  private func readModelCalls(where predicate: String, values: [SQLValue]) throws -> [ModelCall] {
    try locked {
      var result: [ModelCall] = []
      try connection.namedRows(
        """
        SELECT ts, start_ts, end_ts, model, input_tokens, cached_tokens, output_tokens, succeeded, table_facts, pending, attempt_id FROM
        model_calls WHERE \(predicate) ORDER BY ts, id
        """,
        values
      ) {
        result.append(
          ModelCall(
            ts: try $0.int("ts"), range: TimeRange(try $0.int("start_ts"), try $0.int("end_ts")),
            model: try $0.text("model"), inputTokens: try $0.int("input_tokens"),
            cachedTokens: try $0.int("cached_tokens"),
            outputTokens: try $0.int("output_tokens"), succeeded: try $0.int("succeeded") != 0,
            tableFacts: try $0.optionalText("table_facts").flatMap { try? JSONDecoder().decode(SummaryCallFacts.self, from: Data($0.utf8)) },
            pending: try $0.int("pending") != 0, attemptID: try $0.optionalText("attempt_id")))
      }
      return result
    }
  }
  /// Recorder health, shared with the window/status readers without consulting credentials.
  public func summaryUnavailableUntil() throws -> TimeInterval? {
    try locked {
      var until: TimeInterval?
      try connection.namedRows("SELECT value FROM settings WHERE key='summary.serviceUnavailableUntil'") {
        until = Double(try $0.text("value"))
      }
      return until
    }
  }
  public func saveSummaryUnavailableUntil(_ until: TimeInterval?) throws {
    try locked {
      try connection.transaction {
        if let until {
          try connection.run("INSERT OR REPLACE INTO settings(key,value) VALUES('summary.serviceUnavailableUntil',?)", [.key(String(until))])
        } else { try connection.run("DELETE FROM settings WHERE key='summary.serviceUnavailableUntil'") }
      }
    }
  }
  @discardableResult public func cleanRetention(at now: Int) throws -> Int {
    try locked {
      let journal = try ModelCallJournal(database: url)
      return try journal.withMaintenanceLock(connection) {
      // Repair in bounded transactions before pruning. Refuse pruning if any pending
      // selection cannot be proven repaired, so a retention prefix cannot shift novelty.
      while try connection.integer("SELECT EXISTS(SELECT 1 FROM screen_payloads WHERE novel_text IS NULL)") != 0 {
        let before = try connection.integer("SELECT e.id FROM screen_payloads p JOIN evidence e ON e.id=p.evidence_id WHERE p.novel_text IS NULL ORDER BY e.ts,e.id LIMIT 1")
        try connection.transaction(collectionMaintenance: true) { try repairCollectionNovelty(limit: 32) }
        guard try connection.integer("SELECT EXISTS(SELECT 1 FROM screen_payloads WHERE evidence_id=? AND novel_text IS NULL)", [.integer(before)]) == 0 else { throw StorageError("Screen compatibility repair made no progress") }
        try connection.collectionMaintenanceYield?()
      }
      let removed = try connection.transaction(collectionMaintenance: true) {
        try requireAXProbeReviewClosed()
        let settings = try self.settings()
        try connection.run("DELETE FROM ax_probe_attempts WHERE ts<?", [.integer(now - settings.screenRetentionDays * 86400)])
        let priorCutoff = try connection.integer("SELECT COALESCE(MAX(screen_cutoff),-9223372036854775808) FROM collection_retention")
        let cutoff = max(now - settings.screenRetentionDays * 86400, priorCutoff)
        try connection.collectionWrite("INSERT INTO collection_retention VALUES(1,?) ON CONFLICT(id) DO UPDATE SET screen_cutoff=MAX(screen_cutoff,excluded.screen_cutoff)", [.integer(cutoff)])
        connection.collectionPrivacyProgressProof = { [unowned self] in
          try self.requireAXProbeReviewClosed()
          guard try self.connection.integer("SELECT count(*) FROM collection_retention WHERE id=1 AND typeof(screen_cutoff)='integer' AND screen_cutoff>=?", [.integer(cutoff)]) == 1 else { throw StorageError("Retention progress cutoff missing") }
        }
        try connection.enableCollectionMaintenanceBatches()
        try connection.collectionWrite("DELETE FROM collection_metadata WHERE ts<?", [.integer(cutoff)])
        guard try connection.integer("SELECT count(*) FROM collection_metadata WHERE ts<?", [.integer(cutoff)]) == 0 else { throw StorageError("Retained expired independent metadata") }
        try preserveCollectionMetadata(in: TimeRange(Int.min, cutoff))
        let children = try collectionPayloadIDs(in: TimeRange(Int.min, cutoff))
        try connection.collectionWrite("UPDATE samples SET window='',document_key='',observed_ts=NULL WHERE observed_ts<?", [.integer(cutoff)])
        guard try connection.integer("SELECT count(*) FROM samples WHERE observed_ts<? AND (window!='' OR document_key!='')", [.integer(cutoff)]) == 0 else { throw StorageError("Retained expired sample metadata") }
        let scrubbedObservations = try scrubObservationMetadata(in: TimeRange(Int.min, cutoff))
        let expiredObservations = Self.expiredCollectionObservations
        try connection.collectionWrite("DELETE FROM sample_observations WHERE id IN (" + expiredObservations + ")", [.integer(cutoff)])
        try connection.collectionWrite("DELETE FROM input_batches WHERE ts<?", [.integer(cutoff)])
        try connection.collectionWrite("DELETE FROM collection_legacy_times WHERE ts<?", [.integer(cutoff)])
        guard try connection.integer("SELECT EXISTS(" + expiredObservations + ")", [.integer(cutoff)]) == 0 else { throw StorageError("Retained expired observations") }
        guard try connection.integer("SELECT count(*) FROM input_batches WHERE ts<?", [.integer(cutoff)]) == 0 else { throw StorageError("Retained expired input") }
        var removed = 0
        try connection.collectionWrite("DELETE FROM evidence WHERE kind='screen' AND ts<?", [.integer(cutoff)])
        removed += connection.collectionLastChanges
        // Prompt duration is mutable during collection gaps. Re-read it only
        // after checkpoint and keep that policy decision with its bounded write.
        while try connection.withCollectionMaintenanceUnit({
          let promptCutoff = now - (try self.settings()).promptRetentionDays * 86400
          try connection.collectionWrite("DELETE FROM evidence WHERE id IN (SELECT id FROM evidence WHERE kind='prompt' AND ts<? LIMIT 64)", [.integer(promptCutoff)])
          let count = connection.collectionLastChanges
          removed += count
          return count > 0
        }) { }
        let expectedMetadata = try scrubScreenMetadata(ids: screenMetadataTargets(in: TimeRange(Int.min, cutoff)))
        try verifyScreenMetadataErasure(expectedMetadata)
        try verifyCollectionErasure(ids: children)
        try verifyScrubbedObservationMetadata(count: scrubbedObservations)
        guard try connection.integer("SELECT count(*) FROM collection_retention WHERE id=1 AND typeof(screen_cutoff)='integer' AND screen_cutoff>=?", [.integer(cutoff)]) == 1 else { throw StorageError("Retention cutoff was not stored") }
        return removed
      }
      _ = connection.truncateWAL()
      let cutoff = try connection.integer("SELECT COALESCE(MAX(screen_cutoff),-9223372036854775808) FROM collection_retention")
      try eraseStagedCollection(in: TimeRange(Int.min, cutoff))
      return removed
      }
    }
  }
}
