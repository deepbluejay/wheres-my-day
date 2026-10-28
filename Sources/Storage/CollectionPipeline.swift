import Core
import CryptoKit
import Foundation

struct CollectionRecord: Codable {
  var observation: ActivityObservation?
  var screen: ScreenTextPayload?
  var time: Int
  var source: String = ""
  var documentKey: String = ""
  var runID: String?
  var attemptID: String?
  var screenJSON: String?
  var observationEvents: Data?
  var eventsOnly: Bool?
  var occurrenceID: String?
  var enqueueSequence: UInt64?
  var metadataObservedAt: Double?
  var applicationPrivacyIdentity: String?
  // Missing versions are envelopes published before versioning (schemas 10–14).
  // Only NULL historical columns may use the pre-14 proof; a stored digest is
  // always authoritative, even in an unversioned envelope.
  var storageVersion: Int? = SQLiteConnection.schemaVersion
  var replayStorageVersion: Int {
    // Schema 14 also added this field inside observation JSON. It distinguishes
    // its unversioned envelopes from schema 13 before admission normalizes them.
    storageVersion ?? (observation?.sample.applicationPrivacyIdentity != nil ? 14 : 13)
  }
  func matchesStoredIdentity(_ stored: String?, incoming: String?) -> Bool {
    if stored == nil && replayStorageVersion < 14 { return true }
    return stored == incoming
  }
  func observationJSON(_ original: ActivityObservation) throws -> String {
    var value = original
    if replayStorageVersion < 14 { value.sample.applicationPrivacyIdentity = nil }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
  func overlaps(_ range: TimeRange) -> Bool {
    if eventsOnly != true && time >= range.start && time < range.end { return true }
    if let observed = metadataObservedAt, observed >= Double(range.start), observed < Double(range.end) { return true }
    if let observed = observation?.sample.observedAt, observed >= Double(range.start), observed < Double(range.end) { return true }
    let events = observationEvents.flatMap { try? CompactInput.decode($0) } ?? observation?.sample.inputEvents ?? []
    return events.contains { $0.timestamp >= Double(range.start) && $0.timestamp < Double(range.end) }
  }
}

/// Admission owns the only memory copy until atomic spool publication succeeds.
public final class CollectionPipeline {
  public enum CaptureAdmission { case accepted, deferred, dropped }
  public struct Completion {
    public var storedObservations = 0
    public var screen: ScreenCaptureResult?
    public var attemptID: String?
    public var time = 0
    public var ocrBytes = 0
  }
  public struct AdmissionLoss {
    public let source: String
    public let sourceDigest: String
    public let time: Int
    public let capture: Bool
    public let bytes: Int
    public let reason = "admission_deadline"
  }
  public struct Diagnostics {
    public var acquisitionFailures = 0
    public var stagingFailures = 0
    public var persistenceFailures = 0
    public var initializationFailures = 0
    public var diagnosticPublicationFailures = 0
    public var droppedObservations = 0
    public var droppedCaptures = 0
    public var lastDropSource: String?
    public var lastDropTime: Int?
    public var losses: [AdmissionLoss] = []
    public var evictedLossReceipts = 0
    public var retainedBytes = 0
  }
  private struct Pending {
    var bytes: Int
    var oversized: Bool
    var prepare: (() throws -> CollectionRecord)?
    var record: CollectionRecord?
  }
  private let queue = DispatchQueue(label: "ActivityProbe.CollectionWriter", qos: .utility)
  private let lock = NSLock()
  private var writer: ActivityStorage?
  private let database: URL?
  private let openWriter: () throws -> ActivityStorage
  private let admission = NSCondition()
  private var queuedBytes = 0
  private var oversizedBytes = 0
  public static let queueBytes = 8 * 1024 * 1024
  public static let overflowBytes = 1024 * 1024
  private var pending: [Pending] = []
  private var completions: [Completion] = []
  private var diagnostics = Diagnostics()
  private var failures = 0
  private var busyRetries = 0
  private var writeBlocked = false
  private var publicationBlocked = false
  private var retryScheduled = false
  private var recoveryCursor: CollectionFileCursor?
  private var recoverySequence: UInt64 = 0
  private var backpressure = 0
  init(database: URL? = nil, openWriter: @escaping () throws -> ActivityStorage) { self.database = database; self.openWriter = openWriter }
  init(writer: ActivityStorage) { self.database = writer.url; self.writer = writer; self.openWriter = { writer } }
  @discardableResult private func offer(bytes: Int, source: String, time: Int, capture: Bool,
    deferOversized: Bool = false, prepare: @escaping () throws -> CollectionRecord) -> CaptureAdmission {
    admission.lock()
    let oversized = capture && bytes > Self.queueBytes
    func exceeds(_ limit: Int) -> Bool {
      if oversized { return oversizedBytes > 0 }
      let ordinary = queuedBytes - oversizedBytes
      return ordinary > 0 && ordinary + bytes > limit
    }
    if exceeds(Self.queueBytes) {
      backpressure += 1
      _ = admission.wait(until: Date(timeIntervalSinceNow: 0.002))
      if exceeds(Self.queueBytes + Self.overflowBytes) {
        admission.unlock()
        // Recorder keeps ownership and retries without turning contention into data loss.
        if oversized && deferOversized { return .deferred }
        lock.lock()
        if capture { diagnostics.droppedCaptures += 1 } else { diagnostics.droppedObservations += 1 }
        let boundedSource = String(decoding: source.utf8.prefix(256), as: UTF8.self)
        diagnostics.lastDropSource = boundedSource; diagnostics.lastDropTime = time
        if diagnostics.losses.count == 64 { diagnostics.losses.removeFirst(); diagnostics.evictedLossReceipts += 1 }
        diagnostics.losses.append(AdmissionLoss(source: boundedSource, sourceDigest: SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined(), time: time, capture: capture, bytes: bytes))
        lock.unlock()
        return .dropped
      }
    }
    queuedBytes += bytes
    if oversized { oversizedBytes = bytes }
    admission.unlock()
    // Screen captures and activity samples share this writer; each is measured as its stage.
    queue.async { StageUsage.shared.measure(capture ? "screen_collection" : "sample_collection") { items in
      items["writes"] = 1
      var work = Pending(bytes: bytes, oversized: oversized, prepare: prepare)
      do { work.record = try prepare(); work.prepare = nil }
      catch { self.record(error, phase: 0) }
      self.pending.append(work)
      if !self.publicationBlocked { self.publishPending() }
      if !self.writeBlocked { self.persistReady() }
    } }
    return .accepted
  }
  @discardableResult public func offer(_ observation: ActivityObservation) -> Bool {
    let sample = observation.sample
    let strings = [observation.id, sample.bundleID, sample.app, sample.window, sample.documentKey]
      + [sample.document, sample.browserAddress, sample.accessibility].compactMap { $0 }
    let bytes = 512 + sample.inputEvents.count * 128 + strings.reduce(0) { $0 + $1.utf8.count }
    return offer(bytes: bytes, source: sample.bundleID, time: sample.ts, capture: false) {
      // Mask before publication, but let the shared policy count every acquired
      // component before acquisition-time exclusion blanks it.
      var value = observation
      value.sample.excluded = false
      value = value.redacted()
      value.sample.excluded = sample.excluded
      let events = CompactInput.encode(value.sample.inputEvents); value.sample.inputEvents = []
      return CollectionRecord(observation: value, time: sample.ts, observationEvents: events)
    } == .accepted
  }
  @discardableResult public func offer(payload: ScreenTextPayload, at time: Int, source: String, documentKey: String,
    runID: String?, attemptID: String?, metadataObservedAt: Double? = nil) -> Bool {
    offerCapture(payload: payload, at: time, source: source, documentKey: documentKey, runID: runID,
      attemptID: attemptID, metadataObservedAt: metadataObservedAt, deferOversized: false) == .accepted
  }
  /// A busy oversized slot leaves ownership with the recorder, without dropping the capture.
  public func handoff(payload: ScreenTextPayload, at time: Int, source: String, documentKey: String,
    runID: String?, attemptID: String?, metadataObservedAt: Double? = nil) -> CaptureAdmission {
    offerCapture(payload: payload, at: time, source: source, documentKey: documentKey, runID: runID,
      attemptID: attemptID, metadataObservedAt: metadataObservedAt, deferOversized: true)
  }
  private func offerCapture(payload: ScreenTextPayload, at time: Int, source: String, documentKey: String,
    runID: String?, attemptID: String?, metadataObservedAt: Double?, deferOversized: Bool) -> CaptureAdmission {
    let bytes = payload.estimatedBytes * 4 + source.utf8.count + documentKey.utf8.count + 128
    return offer(bytes: bytes, source: source, time: time, capture: true, deferOversized: deferOversized) {
      let value = payload.redacted()
      return CollectionRecord(screen: value, time: time, source: Redaction.applyKnownSecrets(source).text,
        documentKey: Redaction.apply(documentKey).text, runID: runID, attemptID: attemptID,
        screenJSON: try screenPayloadJSON(value), occurrenceID: UUID().uuidString, metadataObservedAt: metadataObservedAt,
        applicationPrivacyIdentity: ApplicationPrivacyIdentity.originalDigest(source))
    }
  }
  private func ensureWriter() throws -> ActivityStorage {
    if let writer { return writer }
    do { let value = try openWriter(); writer = value; return value }
    catch {
      if case StorageError.busy = error { throw error }
      lock.lock(); diagnostics.initializationFailures += 1; lock.unlock()
      persistHealth(phase: 3); throw error
    }
  }
  private func publishPending() {
    while !pending.isEmpty {
      if pending[0].record == nil {
        do { pending[0].record = try pending[0].prepare!(); pending[0].prepare = nil }
        catch { record(error, phase: 0); publicationBlocked = true; return }
      }
      do {
        let writer = try ensureWriter()
        let published = try writer.stageCollection(&pending[0].record!)
        if !published, let record = pending[0].record, record.screen != nil {
          let result = Completion(screen: ScreenCaptureResult(append: AppendResult(refused: 1), addedKeys: []),
            attemptID: record.attemptID, time: record.time)
          lock.lock(); completions.append(result); lock.unlock()
        }
        let publishedWork = pending.removeFirst()
        admission.lock()
        queuedBytes -= publishedWork.bytes
        if publishedWork.oversized { oversizedBytes = 0 }
        admission.broadcast(); admission.unlock()
      } catch { record(error, phase: 1); publicationBlocked = true; return }
    }
    publicationBlocked = false
  }
  public func retry() {
    lock.lock()
    guard !retryScheduled else { lock.unlock(); return }
    retryScheduled = true; lock.unlock()
    queue.async {
      defer { self.lock.lock(); self.retryScheduled = false; self.lock.unlock() }
      self.publishPending(); self.persistReady()
    }
  }
  /// Stop/tests may wait. Ordinary ticks have a two millisecond admission deadline.
  public func drain() { queue.sync { publishPending(); persistReady() } }
  private func persistReady() {
    do { try drainBatch(); writeBlocked = false }
    catch { writeBlocked = true; record(error, phase: 2) }
  }
  private func record(_ error: Error, phase: Int) {
    lock.lock()
    let busy: Bool
    if case StorageError.busy = error { busy = true } else { busy = false }
    if busy { busyRetries += 1 }
    else {
      if phase == 0 { diagnostics.acquisitionFailures += 1 }
      if phase == 1 { diagnostics.stagingFailures += 1 }
      if phase == 2 { diagnostics.persistenceFailures += 1 }
      failures += 1
    }
    lock.unlock()
    persistHealth(phase: busy ? 4 : phase)
  }
  private func persistHealth(phase: Int) {
    guard let database else { return }
    do { try CollectionOperationalHealth.increment(phase, database: database) }
    catch { lock.lock(); diagnostics.diagnosticPublicationFailures += 1; lock.unlock() }
  }
  public func clearDiagnosticIdentities() {
    lock.lock(); defer { lock.unlock() }
    diagnostics.lastDropSource = nil; diagnostics.lastDropTime = nil; diagnostics.losses.removeAll()
  }
  public func takeDiagnostics() -> Diagnostics {
    lock.lock(); var value = diagnostics; diagnostics = Diagnostics(); lock.unlock()
    admission.lock(); value.retainedBytes = queuedBytes; admission.unlock()
    return value
  }
  public func takeCompletions() -> ([Completion], Int, Int, Int) {
    lock.lock(); defer { lock.unlock() }
    let result = completions; completions.removeAll()
    let errors = failures; failures = 0
    let busy = busyRetries; busyRetries = 0
    admission.lock(); let pressure = backpressure; backpressure = 0; admission.unlock()
    return (result, errors, pressure, busy)
  }
  private func drainBatch() throws {
    let writer = try ensureWriter()
    let journal = try ModelCallJournal(database: writer.url)
    var quarantinedFailures: [Error] = []
    // Operational health takes the journal lock too; publish after releasing it.
    defer { for error in quarantinedFailures { self.record(error, phase: 2) } }
    try journal.withLock {
      if recoveryCursor == nil {
        recoveryCursor = try writer.collectionRecoveryCursor()
        recoverySequence = try writer.collectionRecoverySequence()
      } else {
        // Publication assigns durable increasing names under this same barrier.
        // Add only the new sequence interval, without rescanning the backlog.
        let latest = try writer.collectionRecoverySequence()
        if latest > recoverySequence {
          for sequence in (recoverySequence + 1)...latest {
            try recoveryCursor!.add(String(format: "r-%020llu.json", sequence))
          }
          recoverySequence = latest
        }
      }
      var acknowledged = 0
      while acknowledged < 32 {
        let names = try recoveryCursor!.batch(limit: 32 - acknowledged)
        if names.isEmpty { recoveryCursor = nil; break }
        for name in names {
          let file = writer.collectionDirectory.appendingPathComponent(name)
          if acknowledged == 32 { break }
          if try !OperationalDirectory(writer.collectionDirectory).exists(name) {
            recoveryCursor!.acknowledge(name); continue
          }
          guard let record = try writer.readReadyCollection(file) else {
            recoveryCursor!.acknowledge(name); continue
          }
          var completed = Completion(time: record.time)
          do { try writer.locked {
            if record.screen != nil { writer.repairPendingCollectionNovelty() }
            try writer.connection.transaction {
              try writer.withCollectionAdmission(record) { allowed in
                if allowed.observation != nil {
                  completed.storedObservations = try writer.insertAdmittedObservation(allowed) ? 1 : 0
                } else if let payload = allowed.screen {
                  if allowed.eventsOnly == true {
                    try writer.insertIndependentMetadata(allowed)
                    completed.screen = ScreenCaptureResult(append: AppendResult(refused: 1), addedKeys: [])
                  } else {
                    let probe = allowed.runID.flatMap { run in allowed.attemptID.map { AXProbeLink(runID: run, attemptID: $0) } }
                    completed.screen = try writer.insertAdmittedScreen(allowed, project: "", probe: probe)
                  }
                  completed.attemptID = allowed.attemptID; completed.ocrBytes = payload.text.utf8.count
                }
              }
            }
          } } catch {
            if case StorageError.busy = error { throw error }
            // Busy storage preserves ownership indefinitely. Other unprovable
            // transactions get eight durable attempts, including cold restarts.
            // Explicit immutable-identity collisions need no further attempts.
            if !(error is CollectionReplayFailure), try writer.countUnprovenCollection(file) < 8 { throw error }
            // The transaction rolled back. Keep the masked envelope visible to
            // privacy erasure, but retire it from the ordered recovery cursor.
            try writer.quarantineUnrecoverableCollection(file)
            recoveryCursor!.acknowledge(name)
            acknowledged += 1
            quarantinedFailures.append(error)
            continue
          }
          try writer.removeCollectionFile(file)
          try writer.clearCollectionRetry(file)
          recoveryCursor!.acknowledge(name)
          acknowledged += 1
          lock.lock()
          if completed.screen == nil, let index = completions.firstIndex(where: { $0.screen == nil }) { completions[index].storedObservations += completed.storedObservations }
          else { completions.append(completed) }
          lock.unlock()
        }
      }
    }
  }
}

extension ActivityStorage {
  public func makeCollectionPipeline(ownBundleID: String? = nil) -> CollectionPipeline {
    let identity = ownBundleID ?? self.ownBundleID
    if let collectionWriterFactory { return CollectionPipeline(database: url, openWriter: collectionWriterFactory) }
    return CollectionPipeline(database: url) { [url, appDataDirectory, databaseScope] in
      try ActivityStorage(url: url, appDataDirectory: appDataDirectory, busyMilliseconds: 0, databaseScope: databaseScope, ownBundleID: identity)
    }
  }
}
