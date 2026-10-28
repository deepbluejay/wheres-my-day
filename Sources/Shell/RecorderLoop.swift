import Core
import Foundation
import Storage

extension ActivityStorage: RecorderStorage {}

public struct RecorderHealth {
  public var absentSources: [RecorderSource: SourceAbsence] = [:]
  public var storedSeconds = 0
  public var refusedSeconds = 0
  public var refusedCaptures = 0
  public var policyRefusedCaptures = 0
  public var captureFailures = 0
  public var inputUnavailableTicks = 0
  public var nativeEventLimitRefusals = 0
  public var settingsUnreadableCaptures = 0
  public var supersededCaptures = 0
  public var droppedSeconds = 0
  public var droppedCaptures = 0
  public var pendingSeconds = 0
  public var pendingCaptures = 0
  public var pendingObservations = 0
  public var droppedObservations = 0
  public var storedOCRBytes = 0
  public var storedObservations = 0
  public var collectionBackpressure = 0
  public var collectionFailures = 0
  public var collectionBusyRetries = 0
  public var collectionAcquisitionFailures = 0
  public var collectionStagingFailures = 0
  public var collectionPersistenceFailures = 0
  public var collectionInitializationFailures = 0
  public var collectionRetainedBytes = 0
  public var collectionDiagnosticPublicationFailures = 0
  public var collectionLastDropSource: String?
  public var collectionLastDropTime: Int?
  public var collectionLastAdmissionLosses: [CollectionPipeline.AdmissionLoss] = []
  public var collectionEvictedLossReceipts = 0
  public var maintenanceFailures: [String: Int] = [:]
  public var storageBusy = false
  public var storageFailed = false
}

public struct RecorderMaintenanceTask {
  public let name: String
  public let run: (Int) throws -> Void
  public let cancel: () -> Void
  public let finish: (@escaping () -> Void) -> Void
  public init(name: String, cancel: @escaping () -> Void = {}, finish: @escaping (@escaping () -> Void) -> Void = { $0() }, run: @escaping (Int) throws -> Void) {
    self.name = name
    self.run = run
    self.cancel = cancel; self.finish = finish
  }
}

private struct PendingCapture {
  var bytes: Int {
    (payload?.estimatedBytes ?? text.utf8.count) + source.utf8.count + documentKey.utf8.count + 128
  }
  var attemptID: String? = nil
  var probeRunID: String? = nil
  var time: Int
  var source: String
  var documentKey: String
  var text: String
  var payload: ScreenTextPayload? = nil
  var metadataObservedAt: Double? = nil

  // A received large payload gets its own slot; it cannot consume the ordinary budget.
  static func fits(_ capture: PendingCapture, beside waiting: [PendingCapture]) -> Bool {
    if capture.bytes > CollectionPipeline.queueBytes {
      return !waiting.contains { $0.bytes > CollectionPipeline.queueBytes }
    }
    let ordinary = waiting.filter { $0.bytes <= CollectionPipeline.queueBytes }
    return ordinary.count < RecorderTiming.pendingCaptures
      && ordinary.reduce(0, { $0 + $1.bytes }) + capture.bytes <= CollectionPipeline.queueBytes
  }
}

/// Health reads, start, stop, tick and flush are main-thread only.
/// Sources must support completion-thread privacy reads.
public final class RecorderLoop {
  // Immutable dependencies may be used by completion threads.
  private let clock: RecorderClock
  private let input: InputCountSource
  private let front: FrontWindowSource
  private let secure: SecureInputSource
  private let awake: DisplayAwakeSource
  private let screen: ScreenTextSource
  private let storage: RecorderStorage
  private let ownBundleID: String
  // Main thread owns scheduling, pending rows, health and key memory.
  private var suspended = false
  private var stopped = false
  private var captureGeneration = 0
  private var activeCaptures = Set<UUID>()
  private var timer: Timer?
  private var schedule = CaptureSchedule()
  public private(set) var health = RecorderHealth()
  public var recordingDisabled: (() -> Void)?
  public var pendingCaptureCompletions: Int {
    inboxLock.lock()
    defer { inboxLock.unlock() }
    return inbox.count
  }
  private var pending: [TimeSample] = []
  private var pendingObservations: [ActivityObservation] = []
  private let collectionPipeline: CollectionPipeline?
  private var collectionAttempts = Set<String>()
  private var captures: [PendingCapture] = []
  private var probeInbox: [(AXProbeReceipt, Int)] = []
  private var probePending: [(AXProbeReceipt, Int)] = []
  private let probePipeline: AXProbePipeline?
  private var probeEvidence: [String: (Int?, Int, AXProbeOCRRefusal?)] = [:]
  private var lastFlush: Int?
  private var lastTick: Int?
  private var lastTickUptime: Double?
  private var lastTickActive = false
  private var lastQueuedSecond: Int?
  private var lastPersonInput: Int?
  private var carriedInput = InputCounts()
  private var retryingWrites = false
  private var deletionCount: Int?
  private var metadataPolicy: String?
  // inboxLock owns completions, losses, and maintenance running/results.
  private let inboxLock = NSLock()
  private var inbox: [(PendingCapture, SourceAbsence?)] = []
  private var inboxDropped = 0
  // Immutable queue/tasks; lastMaintenance belongs to the main thread.
  private let maintenanceQueue = DispatchQueue(label: "ActivityProbe.Shell.Maintenance")
  let maintenanceStorage: EvidenceRetention
  private let maintenanceTasks: [RecorderMaintenanceTask]
  private var lastMaintenance: Int?
  private var maintenanceRunning = false
  private var maintenanceResults: [String] = []
  /// Called on the maintenance queue after each tick's tasks with every stage's usage.
  var publishUsage: ((StageUsage.Snapshot) -> Void)?
  let usage: StageUsage

  public init(
    clock: RecorderClock, input: InputCountSource, front: FrontWindowSource,
    secure: SecureInputSource, awake: DisplayAwakeSource, screen: ScreenTextSource,
    storage: RecorderStorage, maintenanceStorage: EvidenceRetention, ownBundleID: String,
    maintenanceTasks: [RecorderMaintenanceTask] = [], probePipeline: AXProbePipeline? = nil, usage: StageUsage = .shared
  ) {
    self.usage = usage
    self.clock = clock
    self.input = input
    self.front = front
    self.secure = secure
    self.awake = awake
    self.screen = screen
    self.maintenanceStorage = maintenanceStorage
    self.storage = storage
    self.collectionPipeline = (storage as? ActivityStorage)?.makeCollectionPipeline(ownBundleID: ownBundleID)
    if let probePipeline { self.probePipeline = probePipeline }
    else if let store = storage as? AXProbeStore {
      self.probePipeline = AXProbePipeline(write: { pair, evidence, now, gate in
        _ = try store.appendAXProbe(pair, evidenceID: evidence, at: now, permitted: gate)
      }, dropped: { receipt in try? store.countAXProbeOverload(receipt) },
        failed: { receipt in try? store.recordAXProbePersistenceFailure(receipt) })
    } else { self.probePipeline = nil }
    self.ownBundleID = ownBundleID
    self.maintenanceTasks =
      [
        RecorderMaintenanceTask(name: "retention") { now in
          // A separate client connection avoids holding the recorder object's lock during background work.
          try usage.measure("retention") { items in items["removed"] = try maintenanceStorage.cleanRetention(at: now) }
        }
      ] + maintenanceTasks
  }
  public func start() {
    precondition(Thread.isMainThread)
    guard timer == nil, !stopped else { return }
    let timer = Timer(timeInterval: Double(RecorderTiming.sampleSeconds), repeats: true) { [weak self] _ in
      self?.tick()
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  /// The shell must call stop before release. Deinit alone discards pending work without counting it.
  public func stop() {
    precondition(Thread.isMainThread)
    let cancelMaintenance = !stopped
    inboxLock.lock()
    stopped = true; captureGeneration += 1
    probeInbox.removeAll()
    health.droppedCaptures += activeCaptures.count
    activeCaptures.removeAll()
    inboxLock.unlock()
    if cancelMaintenance { for task in maintenanceTasks { task.cancel() } }
    (screen as? AXProbeScreenSource)?.invalidateProbe()
    probePending.removeAll(); probeEvidence.removeAll(); probePipeline?.discardWaiting()
    timer?.invalidate()
    timer = nil
    // A barrier can free a large slot for the next owned completion. Keep handing
    // off while ownership advances, and never enqueue after the final barrier.
    var remaining = pending.count + pendingObservations.count + captures.count + pendingCaptureCompletions
    repeat {
      let before = remaining
      flush()
      collectionPipeline?.drain()
      drainCollectionResults()
      remaining = pending.count + pendingObservations.count + captures.count + pendingCaptureCompletions
      if remaining == 0 || remaining >= before { break }
    } while true
    health.droppedSeconds += pending.count
    health.droppedCaptures += captures.count
    inboxLock.lock()
    health.droppedCaptures += inbox.count
    inbox.removeAll()
    inboxLock.unlock()
    pending.removeAll()
    health.droppedObservations += pendingObservations.count
    pendingObservations.removeAll()
    captures.removeAll()
    updatePendingHealth()
  }
  /// A barrier lets the host retain the connections until owned maintenance has finished.
  public func finishMaintenance(_ completion: @escaping () -> Void) {
    maintenanceQueue.async {
      let group = DispatchGroup()
      for task in self.maintenanceTasks { group.enter(); task.finish { group.leave() } }
      group.notify(queue: self.maintenanceQueue) {
        if let pipeline = self.probePipeline { pipeline.drain { DispatchQueue.main.async { completion() } } }
        else { DispatchQueue.main.async { completion() } }
      }
    }
  }
  public func setSuspended(_ value: Bool) {
    precondition(Thread.isMainThread)
    guard suspended != value, !stopped else { return }
    inboxLock.lock()
    suspended = value; captureGeneration += 1
    probeInbox.removeAll()
    inboxLock.unlock()
    probePending.removeAll(); probeEvidence.removeAll(); probePipeline?.discardWaiting()
    _ = input.takeInput()
    lastPersonInput = nil; carriedInput = InputCounts()
    lastTickUptime = nil; lastTickActive = false
    if value { front.invalidateMetadata() }
    if value { (screen as? AXProbeScreenSource)?.invalidateProbe(); flush() }
  }
  public func requestMaintenance() {
    precondition(Thread.isMainThread)
    guard !stopped else { return }
    scheduleMaintenance(at: clock.now, force: true)
  }
  deinit {
    if let timer {
      if Thread.isMainThread {
        timer.invalidate()
      } else {
        DispatchQueue.main.async { timer.invalidate() }
      }
    }
  }
  private func read<T>(_ reading: SourceReading<T>, source: RecorderSource) -> T? {
    switch reading {
    case .value(let value):
      health.absentSources.removeValue(forKey: source)
      return value
    case .absent(let reason):
      health.absentSources[source] = reason
      return nil
    }
  }
  private func failure(_ error: Error) {
    if case StorageError.busy = error { health.storageBusy = true } else { health.storageFailed = true }
  }
  private func settingsAndApplyDeletions() throws -> StorageSettings {
    let settings = try storage.settings()
    let policy = "\(settings.recordingEnabled)|\(settings.pausedUntil ?? 0)|" + settings.persistedAppExclusions.map(\.identity).sorted().joined(separator: "|")
    if let metadataPolicy, metadataPolicy != policy { front.invalidateMetadata() }
    metadataPolicy = policy
    let count = try storage.deletionsSoFar()
    if let deletionCount, count != deletionCount {
      front.invalidateMetadata()
      collectionPipeline?.clearDiagnosticIdentities()
      health.collectionLastDropSource = nil; health.collectionLastDropTime = nil
      health.collectionLastAdmissionLosses.removeAll()
      health.droppedCaptures += captures.count
      captures.removeAll()
      inboxLock.lock()
      health.droppedCaptures += inbox.count
      inbox.removeAll()
      inboxLock.unlock()
      (screen as? AXProbeScreenSource)?.invalidateProbe()
      probePending.removeAll(); probeEvidence.removeAll(); probePipeline?.discardWaiting()
    }
    deletionCount = count
    return settings
  }
  private func drainInbox() {
    drainCollectionResults()
    inboxLock.lock()
    // Leave the next oversized completion in its owned slot until the main-thread slot is free.
    let holdsOversized = captures.contains { $0.bytes > CollectionPipeline.queueBytes }
    let completed = inbox.filter { !holdsOversized || $0.0.bytes <= CollectionPipeline.queueBytes }
    let probes = probeInbox
    probeInbox.removeAll()
    inbox.removeAll { !holdsOversized || $0.0.bytes <= CollectionPipeline.queueBytes }
    health.droppedCaptures += inboxDropped
    inboxDropped = 0
    for name in maintenanceResults { health.maintenanceFailures[name, default: 0] += 1 }
    maintenanceResults.removeAll()
    inboxLock.unlock()
    for probe in probes {
      if probePending.count < RecorderTiming.pendingCaptures { probePending.append(probe) }
      else { probePipeline?.discard(probe.0); try? (storage as? AXProbeStore)?.countAXProbeEvent(runID: probe.0.runID, event: .pendingDropped, amount: 1) }
    }
    for (capture, absence) in completed {
      health.absentSources.removeValue(forKey: .screen)
      if let absence {
        if let id = capture.attemptID { probeEvidence[id] = (nil, capture.time, nil) }
        switch absence {
        case .policyRefused:
          health.policyRefusedCaptures += 1
        case .failed:
          health.captureFailures += 1
        case .settingsUnreadable:
          health.settingsUnreadableCaptures += 1
        case .superseded:
          health.supersededCaptures += 1
        default:
          health.absentSources[.screen] = absence
        }
        continue
      }
      health.absentSources.removeValue(forKey: .screen)
      if PendingCapture.fits(capture, beside: captures) {
        captures.append(capture)
      } else {
        health.droppedCaptures += 1
        if let id = capture.attemptID { probeEvidence[id] = (nil, capture.time, .dropped) }
        if let run = capture.probeRunID {
          try? (storage as? AXProbeStore)?.countAXProbeEvent(runID: run, event: .droppedOCR, amount: 1)
          try? (storage as? AXProbeStore)?.countAXProbeEvent(runID: run, event: .ocr_dropped, amount: 1)
        }
      }
    }
  }
  private func allowedApplication(_ application: FrontObservation, settings: StorageSettings) -> Bool {
    !RecorderPolicy.excluded(application, settings: settings)
      && application.bundleID.lowercased() != ownBundleID.lowercased()
  }
  private func observeFront(settings: StorageSettings) -> FrontObservation {
    let application = front.frontApplication()
    guard allowedApplication(application, settings: settings) else { return application }
    return front.details(for: application)
  }
  public func tick() {
    guard !stopped else { return }
    let now = clock.now
    let tickUptime = ProcessInfo.processInfo.systemUptime
    // Always drain during pauses. A second without a tick has no row; gaps are not invented.
    let inputReading = input.takeInput()
    if case .absent = inputReading { health.inputUnavailableTicks += 1 }
    let counts = read(inputReading, source: .input) ?? InputCounts()
    health.nativeEventLimitRefusals += counts.detailedEventOverflow
    if !suspended { observeInputActivity(counts, at: now) }
    health.storageBusy = false
    health.storageFailed = false
    scheduleMaintenance(at: now)
    let settings: StorageSettings
    // Cooldown/watchdog can prevent begin; failed probe bookkeeping must not stop ordinary recording.
    do { try (storage as? AXProbeStore)?.retryAXProbeFinishes() } catch { failure(error) }
    do { settings = try settingsAndApplyDeletions() } catch {
      if RestPolicy.recordsSecond(at: now, lastInput: lastPersonInput, keepingAwake: false) {
        health.droppedSeconds += 1
      }
      failure(error)
      flushSamples(at: now)
      updatePendingHealth()
      return
    }
    if !settings.recordingEnabled, let recordingDisabled { recordingDisabled(); return }
    let activeTick = !suspended && RecorderPolicy.recording(settings, at: now)
      && RestPolicy.recordsSecond(at: now, lastInput: lastPersonInput, keepingAwake: false)
    if activeTick && lastTickActive, let run = settings.axProbeRun,
      let store = storage as? AXProbeStore, let previous = lastTickUptime {
      // Wall-clock steps do not imply missed timer firings.
      let gap = max(0, Int((tickUptime - previous) / Double(RecorderTiming.sampleSeconds)) - 1)
      let late = max(0, Int((tickUptime - previous - 1) * 1000))
      try? store.countAXProbeEvent(runID: run.id, event: .scheduledTickGaps, amount: gap)
      try? store.countAXProbeEvent(runID: run.id, event: .tickLateMilliseconds, amount: late)
    }
    lastTickActive = activeTick; lastTickUptime = tickUptime
    drainInbox()
    if !suspended && RecorderPolicy.recording(settings, at: now) {
      for details in front.takeCompletedDetails() {
        let observed = details.observedAt.map { Int($0) } ?? now
        let sample = RecorderPolicy.sample(at: observed, front: details, input: InputCounts(),
          keepingAwake: false, settings: settings, ownBundleID: ownBundleID)
        enqueueObservation(ActivityObservation(sample: sample))
      }
      observeSecond(at: now, counts: counts, settings: settings)
    } else {
      front.invalidateMetadata()
      carriedInput = InputCounts()
    }
    lastTick = now
    if lastFlush == nil || now < lastFlush! || now - lastFlush! >= RecorderTiming.batchSeconds
      || retryingWrites
    {
      flush(at: now)
    }
    updatePendingHealth()
  }
  private func observeInputActivity(_ counts: InputCounts, at now: Int) {
    if let lastPersonInput, lastPersonInput > now { self.lastPersonInput = nil }
    if counts.byPerson { lastPersonInput = now }
  }
  private func observeSecond(at now: Int, counts: InputCounts, settings: StorageSettings) {
    let focus = observeFront(settings: settings)
    health.absentSources[.accessibility] = focus.accessibility
    let secured = read(secure.secureInput(), source: .secureInput)
    let watching =
      read(
        awake.keepingDisplayAwake(processID: focus.processID),
        source: .displayAssertions) ?? false
    var rowInput = counts
    rowInput.add(carriedInput)
    let row = RecorderPolicy.sample(
      at: now, front: focus, input: rowInput,
      keepingAwake: watching, settings: settings, ownBundleID: ownBundleID)
    queueObservation(row, counts: counts)
    if RestPolicy.recordsSecond(at: now, lastInput: lastPersonInput, keepingAwake: watching) {
      queueSecond(row, counts: counts)
    }
    let ordinaryOpportunity = RecorderPolicy.captureAllowed(
      front: focus, input: counts, secureInput: secured,
      settings: settings, ownBundleID: ownBundleID, at: now)
    let probeOpportunity = settings.axProbeRun != nil && secured == false
      && allowedApplication(focus, settings: settings) && RecorderPolicy.recording(settings, at: now)
    if ordinaryOpportunity || probeOpportunity, let window = focus.window,
      schedule.reserve(window, at: now)
    {
      requestCapture(window: window, focus: focus, counts: counts, settings: settings, at: now)
    }
  }
  private func enqueueObservation(_ observation: ActivityObservation) {
    if let collectionPipeline { collectionPipeline.offer(observation) }
    else if pendingObservations.count < RecorderTiming.pendingSeconds { pendingObservations.append(observation) }
    else { health.droppedObservations += 1 }
  }
  private func drainCollectionResults() {
    guard let collectionPipeline else { return }
    let (results, errors, pressure, busy) = collectionPipeline.takeCompletions()
    health.collectionFailures += errors; health.collectionBackpressure += pressure
    let diagnostics = collectionPipeline.takeDiagnostics()
    health.collectionAcquisitionFailures += diagnostics.acquisitionFailures
    health.collectionStagingFailures += diagnostics.stagingFailures
    health.collectionPersistenceFailures += diagnostics.persistenceFailures
    health.collectionInitializationFailures += diagnostics.initializationFailures
    health.collectionRetainedBytes = diagnostics.retainedBytes
    health.collectionDiagnosticPublicationFailures += diagnostics.diagnosticPublicationFailures
    health.collectionEvictedLossReceipts += diagnostics.evictedLossReceipts
    if !diagnostics.losses.isEmpty { health.collectionLastAdmissionLosses = diagnostics.losses }
    health.droppedObservations += diagnostics.droppedObservations
    health.droppedCaptures += diagnostics.droppedCaptures
    if let time = diagnostics.lastDropTime {
      health.collectionLastDropTime = time; health.collectionLastDropSource = diagnostics.lastDropSource
    }
    health.collectionBusyRetries += busy
    if busy > 0 { health.storageBusy = true }
    if errors > 0 { health.storageFailed = true }
    for result in results {
      health.storedObservations += result.storedObservations
      if let screen = result.screen {
        if let id = result.attemptID { collectionAttempts.remove(id); probeEvidence[id] = (screen.evidenceID, result.time, nil) }
        health.refusedCaptures += screen.append.refused
        if screen.append.stored > 0 { health.storedOCRBytes += result.ocrBytes }
      }
    }
  }
  private func queueObservation(_ row: TimeSample, counts: InputCounts) {
    var observation = row
    observation.keys = counts.keys; observation.clicks = counts.clicks; observation.scrolls = counts.scrolls
    observation.moved = counts.moved; observation.synthetic = counts.synthetic; observation.inputEvents = counts.events
    enqueueObservation(ActivityObservation(sample: observation))
  }
  private func queueSecond(_ row: TimeSample, counts: InputCounts) {
    if lastQueuedSecond == row.ts {
      if let index = pending.lastIndex(where: { $0.ts == row.ts }) {
        pending[index].keys += counts.keys
        pending[index].clicks += counts.clicks
        pending[index].scrolls += counts.scrolls
        pending[index].moved = pending[index].moved || counts.moved
        pending[index].synthetic += counts.synthetic
        pending[index].inputEvents += counts.events
      } else {
        carriedInput.add(counts)
      }
      return
    }
    if pending.count < RecorderTiming.pendingSeconds {
      pending.append(row)
      lastQueuedSecond = row.ts
      carriedInput = InputCounts()
    } else {
      health.droppedSeconds += 1
      carriedInput = InputCounts()
    }
  }
  // Runs on the adapter/completion thread; only immutable dependencies and a locked check state are used.
  private func permitted(
    _ check: CaptureCheck, window: WindowIdentity, documentKey: String,
    counts: InputCounts, at requestedAt: Int, generation: Int, reviewEpoch: String, state: CapturePrivacyState, probe: Bool = false
  ) -> Bool {
    inboxLock.lock()
    let allowed = !suspended && !stopped && captureGeneration == generation
    inboxLock.unlock()
    guard allowed else { state.refuse(.capture_generation); return false }
    if probe && state.privacyRefused { return false }
    let settings: StorageSettings
    do { settings = try storage.settings() } catch {
      state.markSettingsUnreadable()
      return false
    }
    guard (settings.general["axProbe.reviewGeneration"] ?? "") == reviewEpoch else {
      state.refuse(.capture_generation); return false
    }
    let now = clock.now
    guard RecorderPolicy.recording(settings, at: now) else { state.refuse(.recording_off); return false }
    let observed = probe ? front.frontApplication() : observeFront(settings: settings)
    guard observed.bundleID.lowercased() != ownBundleID.lowercased() else { state.refuse(.own_app); return false }
    guard !RecorderPolicy.excluded(observed, settings: settings) else { state.refuse(.excluded_app); return false }
    guard secure.secureInput().value == false else { state.refuse(.secure_input); return false }
    if !probe {
      guard check.allows(requestedAt: requestedAt, now: now) else { state.refuse(.expired); return false }
      guard counts.byPerson else { state.refuse(.no_person_input); return false }
      guard observed.window == window && RecorderPolicy.documentKey(observed) == documentKey else {
        state.refuse(.key_changed); return false
      }
    }
    inboxLock.lock(); defer { inboxLock.unlock() }
    let valid = !suspended && !stopped && captureGeneration == generation
    if !valid { state.refuse(.capture_generation) }
    return valid
  }

  private func requestCapture(window: WindowIdentity, focus: FrontObservation, counts: InputCounts, settings: StorageSettings, at now: Int) {
    let documentKey = RecorderPolicy.documentKey(focus)
    let reviewEpoch = settings.general["axProbe.reviewGeneration"] ?? ""
    let captureID = UUID()
    inboxLock.lock(); let generation = captureGeneration; activeCaptures.insert(captureID); inboxLock.unlock()
    let state = CapturePrivacyState()
    let request = settings.axProbeRun.map { run in
      AXProbeRequest(run: run, attemptID: captureID.uuidString, time: now,
        window: window, bundleID: focus.bundleID, isBrowser: focus.isBrowser, isBrowserKnown: focus.isBrowserKnown)
    }
    if let request, let store = storage as? AXProbeStore {
      try? store.countAXProbeEvent(runID: request.run.id, event: .eligible, amount: 1)
      let opportunity = AXProbePair(request: request, ax: AXProbeResult(status: .pending),
        ocrStatus: "pending", ocr: "",
        imageRequest: nil, imageReturn: nil, ocrCompletion: 0)
      _ = try? store.appendAXProbe(opportunity, evidenceID: nil, at: now, permitted: { true })
    }
    let gate: (CaptureCheck) -> Bool = { [weak self] check in
        self?.permitted(
          check, window: window, documentKey: documentKey, counts: counts, at: now, generation: generation, reviewEpoch: reviewEpoch, state: state) ?? false
      }
    let completion: (SourceReading<ScreenTextPayload>) -> Void = { [weak self] result in
      guard let self else { return }
      var absence: SourceAbsence?
      if case .absent(let reason) = result { absence = reason }
      if result.value != nil
        && !self.permitted(
          .beforeDelivery, window: window,
          documentKey: documentKey, counts: counts, at: now, generation: generation, reviewEpoch: reviewEpoch, state: state)
      {
        absence = .policyRefused
      }
      if state.settingsUnreadable { absence = .settingsUnreadable }
      if let request, let store = self.storage as? AXProbeStore, let absence {
        if absence == .settingsUnreadable || (absence == .policyRefused && state.privacyRefused) {
          try? store.refuseAXProbeOpportunity(runID: request.run.id, attemptID: request.attemptID, reason: state.reason)
        }
        if absence != .policyRefused && absence != .settingsUnreadable,
          let reason = AXProbeOCRRefusal(rawValue: absence.rawValue) { state.refuse(reason) }
        if !state.privacyRefused, let reason = state.reason, let event = AXProbeEvent(rawValue: "ocr_" + reason.rawValue) {
          try? store.countAXProbeEvent(runID: request.run.id, event: event, amount: 1)
        }
        let event: AXProbeEvent? = absence == .settingsUnreadable ? .settingsUnreadable
          : absence == .superseded ? .supersededOCR : absence == .busy ? .busyOCR : nil
        if let event { try? store.countAXProbeEvent(runID: request.run.id, event: event, amount: 1) }
      }
      var payload = result.value ?? ScreenTextPayload(text: "")
      payload.document = focus.document; payload.browserAddress = focus.browserAddress; payload.window = window
      let capture = PendingCapture(
        attemptID: request?.attemptID, probeRunID: request?.run.id, time: now, source: focus.bundleID,
        documentKey: documentKey, text: payload.text, payload: payload, metadataObservedAt: focus.observedAt)
      var capacityDrop = false
      self.inboxLock.lock()
      self.activeCaptures.remove(captureID)
      guard !self.stopped else {
        self.inboxLock.unlock(); return
      }
      if self.suspended || self.captureGeneration != generation {
        // A delivery from before sleep/lock/stop cannot enter a later recording session.
        self.inboxDropped += 1
      } else if PendingCapture.fits(capture, beside: self.inbox.map { $0.0 }) {
        self.inbox.append((capture, absence))
      } else {
        self.inboxDropped += 1; capacityDrop = true
      }
      self.inboxLock.unlock()
      if capacityDrop, let request {
        state.refuse(.dropped)
        try? (self.storage as? AXProbeStore)?.countAXProbeEvent(runID: request.run.id, event: .droppedOCR, amount: 1)
        try? (self.storage as? AXProbeStore)?.countAXProbeEvent(runID: request.run.id, event: .ocr_dropped, amount: 1)
      }
    }
    if let request, let source = screen as? AXProbeScreenSource, let store = storage as? AXProbeStore {
      let probeGate: () -> Bool = { [weak self] in
        guard let self else { return false }
        return self.permitted(.beforeDelivery, window: window, documentKey: documentKey, counts: counts,
          at: now, generation: generation, reviewEpoch: reviewEpoch, state: state, probe: true)
          && ((try? store.axProbeAllowed(request, at: self.clock.now)) == true)
      }
      source.capturePayload(window: window, probe: request, permitted: gate, probePermitted: probeGate,
        probeBegin: { [weak self] in
          guard let self else { return .cancelled }
          do { return try store.beginAXProbe(request, at: self.clock.now) } catch { return .cancelled }
        }, probeEnd: { [weak self] result in
          store.finishAXProbe(request, result: result, at: self?.clock.now ?? Int(Date().timeIntervalSince1970))
        }, probeWatchdogOCR: { pair, accepted in try? store.recordWatchdogOCR(pair, privacyAccepted: accepted) },
        probeRefused: { try? store.refuseAXProbeOpportunity(runID: request.run.id, attemptID: request.attemptID, reason: state.reason) },
        probeCompletion: { [weak self] pair in
          guard let self else { return }
          guard probeGate() else {
            try? store.refuseAXProbeOpportunity(runID: request.run.id, attemptID: request.attemptID, reason: state.reason)
            return
          }
          var pair = pair
          pair.ocr_refusal_reason = state.reason
          if pair.ocr_refusal_reason != nil { pair.ocr = ""; pair.ocrStatus = "policy_refused" }
          guard let receipt = self.probePipeline?.offer(pair, permitted: probeGate) else { return }
          self.inboxLock.lock()
          let accepted = !self.stopped && !self.suspended && self.captureGeneration == generation
          if accepted { self.probeInbox.append((receipt, generation)) }
          self.inboxLock.unlock()
          if !accepted { self.probePipeline?.discard(receipt) }
        }, completion: completion)
    } else { screen.capturePayload(window: window, permitted: gate, completion: completion) }
  }
  public func flush() {
    do {
      _ = try settingsAndApplyDeletions()
      drainInbox()
      flush(at: clock.now)
      collectionPipeline?.drain()
      drainCollectionResults()
      flush(at: clock.now, retryCollection: false)
    } catch {
      failure(error)
      flushSamples(at: clock.now)
    }
    updatePendingHealth()
  }
  private func flushSamples(at now: Int, retryCollection: Bool = true) {
    lastFlush = now
    retryingWrites = false
    if retryCollection { collectionPipeline?.retry() }
    drainCollectionResults()
    if !pendingObservations.isEmpty {
      do { let batch = Array(pendingObservations.prefix(32)); let result = try storage.appendObservations(batch); health.storedObservations += result.stored; pendingObservations.removeFirst(batch.count) }
      catch { failure(error); retryingWrites = true }
    }
    guard !pending.isEmpty else { return }
    do {
      let result = try storage.appendAccountingSamples(pending)
      health.storedSeconds += result.stored
      health.refusedSeconds += result.refused
      pending.removeAll()
    } catch {
      failure(error)
      retryingWrites = true
    }
  }
  private func flush(at now: Int, retryCollection: Bool = true) {
    flushSamples(at: now, retryCollection: retryCollection)
    var deferred: [PendingCapture] = []
    while let capture = captures.first {
      do {
        let current = try storage.settings()
        let app = FrontObservation(bundleID: capture.source)
        guard allowedApplication(app, settings: current) else {
          health.policyRefusedCaptures += 1
          captures.removeFirst()
          continue
        }
        if let collectionPipeline {
          let admission = collectionPipeline.handoff(payload: capture.payload ?? ScreenTextPayload(text: capture.text), at: capture.time,
            source: capture.source, documentKey: capture.documentKey, runID: capture.probeRunID, attemptID: capture.attemptID, metadataObservedAt: capture.metadataObservedAt)
          if admission == .deferred {
            deferred.append(capture); captures.removeFirst(); continue
          }
          if let id = capture.attemptID {
            if admission == .accepted { collectionAttempts.insert(id) }
            else { probeEvidence[id] = (nil, capture.time, .dropped) }
          }
          captures.removeFirst(); continue
        }
        let probe = capture.probeRunID.flatMap { run in
          capture.attemptID.map { AXProbeLink(runID: run, attemptID: $0) }
        }
        let result = try storage.appendScreenCapture(payload: capture.payload ?? ScreenTextPayload(text: capture.text),
          at: capture.time, source: capture.source, documentKey: capture.documentKey, project: "", probe: probe)
        if let id = capture.attemptID { probeEvidence[id] = (result.evidenceID, capture.time, nil) }
        if result.append.stored > 0 { health.storedOCRBytes += Redaction.apply(capture.text).text.utf8.count }
        health.refusedCaptures += result.append.refused
        captures.removeFirst()
      } catch {
        failure(error)
        retryingWrites = true
        break
      }
    }
    captures.insert(contentsOf: deferred, at: 0)
    if storage is AXProbeStore {
      var waiting: [(AXProbeReceipt, Int)] = []
      for (pair, generation) in probePending {
        guard generation == captureGeneration, !suspended, !stopped else { probePipeline?.discard(pair); continue }
        guard let linkage = probeEvidence[pair.attemptID] else {
          if (captures.contains(where: { $0.attemptID == pair.attemptID }) || collectionAttempts.contains(pair.attemptID)), now >= pair.time, now - pair.time <= 60 {
            waiting.append((pair, generation))
          } else { probePipeline?.commit(pair, evidenceID: nil, at: now) }
          continue
        }
        if let reason = linkage.2 { probePipeline?.refuseOCR(pair, reason: reason) }
        probePipeline?.commit(pair, evidenceID: linkage.0, at: now)
      }
      probePending = waiting
      probeEvidence = probeEvidence.filter { now >= $0.value.1 && now - $0.value.1 <= 60 }
    }
  }
  private func updatePendingHealth() {
    health.pendingSeconds = pending.count
    health.pendingObservations = pendingObservations.count
    health.pendingCaptures = captures.count
  }
  private func scheduleMaintenance(at now: Int, force: Bool = false) {
    guard let lastMaintenance = lastMaintenance ?? (force ? now : nil) else {
      self.lastMaintenance = now
      return
    }
    guard force || now < lastMaintenance || now - lastMaintenance >= RecorderTiming.maintenanceSeconds else { return }
    inboxLock.lock()
    guard !maintenanceRunning else {
      inboxLock.unlock()
      return
    }
    maintenanceRunning = true
    inboxLock.unlock()
    self.lastMaintenance = now
    // Background tasks use their own storage connection and publish only under inboxLock.
    maintenanceQueue.async { [weak self, maintenanceTasks] in
      var failures: [String] = []
      for task in maintenanceTasks {
        do { try task.run(now) } catch { failures.append(task.name) }
      }
      guard let self else { return }
      self.publishUsage?(self.usage.roll(at: now))
      self.inboxLock.lock()
      self.maintenanceResults.append(contentsOf: failures)
      self.maintenanceRunning = false
      self.inboxLock.unlock()
    }
  }
}

public struct WallRecorderClock: RecorderClock {
  public init() {}
  public var now: Int { Int(Date().timeIntervalSince1970) }
}

private final class CapturePrivacyState {
  private let lock = NSLock()
  private var unreadable = false
  private var refusal: AXProbeOCRRefusal?
  var reason: AXProbeOCRRefusal? { lock.lock(); defer { lock.unlock() }; return refusal }
  var privacyRefused: Bool {
    guard let reason else { return false }
    return [.recording_off, .excluded_app, .secure_input, .own_app, .settings_unreadable, .capture_generation].contains(reason)
  }
  func refuse(_ reason: AXProbeOCRRefusal) {
    lock.lock(); defer { lock.unlock() }
    let privacy: [AXProbeOCRRefusal] = [.recording_off, .excluded_app, .secure_input, .own_app, .settings_unreadable, .capture_generation]
    if refusal == nil || privacy.contains(reason) { refusal = reason }
  }
  var settingsUnreadable: Bool {
    lock.lock()
    defer { lock.unlock() }
    return unreadable
  }
  func markSettingsUnreadable() {
    lock.lock()
    unreadable = true
    refusal = .settings_unreadable
    lock.unlock()
  }
}
