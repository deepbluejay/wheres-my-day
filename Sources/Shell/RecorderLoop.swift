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
  public var settingsUnreadableCaptures = 0
  public var supersededCaptures = 0
  public var droppedSeconds = 0
  public var droppedCaptures = 0
  public var pendingSeconds = 0
  public var pendingCaptures = 0
  public var maintenanceFailures: [String: Int] = [:]
  public var storageBusy = false
  public var storageFailed = false
}

public struct RecorderMaintenanceTask {
  public let name: String
  public let run: (Int) throws -> Void
  public init(name: String, run: @escaping (Int) throws -> Void) {
    self.name = name
    self.run = run
  }
}

private struct PendingCapture {
  var attemptID: String? = nil
  var probeRunID: String? = nil
  var time: Int
  var source: String
  var documentKey: String
  var text: String
}

/// Health and keyMemory reads, start, stop, tick and flush are main-thread only.
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
  public private(set) var keyMemory = ScreenKeyMemory()
  public private(set) var health = RecorderHealth()
  public var recordingDisabled: (() -> Void)?
  public var pendingCaptureCompletions: Int {
    inboxLock.lock()
    defer { inboxLock.unlock() }
    return inbox.count
  }
  private var pending: [TimeSample] = []
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
  private var needsRebuild = true
  private var deletionCount: Int?
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

  public init(
    clock: RecorderClock, input: InputCountSource, front: FrontWindowSource,
    secure: SecureInputSource, awake: DisplayAwakeSource, screen: ScreenTextSource,
    storage: RecorderStorage, maintenanceStorage: EvidenceRetention, ownBundleID: String,
    maintenanceTasks: [RecorderMaintenanceTask] = [], probePipeline: AXProbePipeline? = nil
  ) {
    self.clock = clock
    self.input = input
    self.front = front
    self.secure = secure
    self.awake = awake
    self.screen = screen
    self.maintenanceStorage = maintenanceStorage
    self.storage = storage
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
          _ = try maintenanceStorage.cleanRetention(at: now)
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
    inboxLock.lock()
    stopped = true; captureGeneration += 1
    probeInbox.removeAll()
    health.droppedCaptures += activeCaptures.count
    activeCaptures.removeAll()
    inboxLock.unlock()
    (screen as? AXProbeScreenSource)?.invalidateProbe()
    probePending.removeAll(); probeEvidence.removeAll(); probePipeline?.discardWaiting()
    timer?.invalidate()
    timer = nil
    flush()
    drainInbox()
    health.droppedSeconds += pending.count
    health.droppedCaptures += captures.count
    pending.removeAll()
    captures.removeAll()
    updatePendingHealth()
  }
  /// A barrier lets the host retain the connections until owned maintenance has finished.
  public func finishMaintenance(_ completion: @escaping () -> Void) {
    maintenanceQueue.async {
      if let pipeline = self.probePipeline { pipeline.drain { DispatchQueue.main.async { completion() } } }
      else { DispatchQueue.main.async { completion() } }
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
    let count = try storage.deletionsSoFar()
    if let deletionCount, count != deletionCount {
      health.droppedCaptures += captures.count
      captures.removeAll()
      inboxLock.lock()
      health.droppedCaptures += inbox.count
      inbox.removeAll()
      inboxLock.unlock()
      (screen as? AXProbeScreenSource)?.invalidateProbe()
      probePending.removeAll(); probeEvidence.removeAll(); probePipeline?.discardWaiting()
      keyMemory = ScreenKeyMemory()
      needsRebuild = true
    }
    deletionCount = count
    return settings
  }
  private func drainInbox() {
    inboxLock.lock()
    let completed = inbox
    let probes = probeInbox
    probeInbox.removeAll()
    inbox.removeAll()
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
      if captures.count < RecorderTiming.pendingCaptures {
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
  private func rebuildKeys(at now: Int) {
    keyMemory.expire(at: now)
    guard needsRebuild else { return }
    do {
      keyMemory.rebuild(try storage.recentScreenLineKeys(at: now), at: now)
      needsRebuild = false
    } catch { failure(error) }
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
    rebuildKeys(at: now)
    if !suspended && RecorderPolicy.recording(settings, at: now) {
      observeSecond(at: now, counts: counts, settings: settings)
    } else {
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
    if RestPolicy.recordsSecond(at: now, lastInput: lastPersonInput, keepingAwake: watching) {
      let row = RecorderPolicy.sample(
        at: now, front: focus, input: rowInput,
        keepingAwake: watching, settings: settings, ownBundleID: ownBundleID)
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
  private func queueSecond(_ row: TimeSample, counts: InputCounts) {
    if lastQueuedSecond == row.ts {
      if let index = pending.lastIndex(where: { $0.ts == row.ts }) {
        pending[index].keys += counts.keys
        pending[index].clicks += counts.clicks
        pending[index].scrolls += counts.scrolls
        pending[index].moved = pending[index].moved || counts.moved
        pending[index].synthetic += counts.synthetic
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
    let completion: (SourceReading<String>) -> Void = { [weak self] result in
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
      let capture = PendingCapture(
        attemptID: request?.attemptID, probeRunID: request?.run.id, time: now, source: focus.bundleID,
        documentKey: documentKey, text: result.value ?? "")
      var capacityDrop = false
      self.inboxLock.lock()
      self.activeCaptures.remove(captureID)
      guard !self.stopped else {
        self.inboxLock.unlock(); return
      }
      if self.suspended || self.captureGeneration != generation {
        // A delivery from before sleep/lock/stop cannot enter a later recording session.
        self.inboxDropped += 1
      } else if self.inbox.count < RecorderTiming.pendingCaptures {
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
      source.captureText(window: window, probe: request, permitted: gate, probePermitted: probeGate,
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
    } else { screen.captureText(window: window, permitted: gate, completion: completion) }
  }
  public func flush() {
    do {
      _ = try settingsAndApplyDeletions()
      drainInbox()
      rebuildKeys(at: clock.now)
      flush(at: clock.now)
    } catch {
      failure(error)
      flushSamples(at: clock.now)
    }
    updatePendingHealth()
  }
  private func flushSamples(at now: Int) {
    lastFlush = now
    retryingWrites = false
    guard !pending.isEmpty else { return }
    do {
      let result = try storage.appendSamples(pending)
      health.storedSeconds += result.stored
      health.refusedSeconds += result.refused
      pending.removeAll()
    } catch {
      failure(error)
      retryingWrites = true
    }
  }
  private func flush(at now: Int) {
    keyMemory.expire(at: now)
    flushSamples(at: now)
    guard !needsRebuild else { return }
    while let capture = captures.first {
      do {
        let current = try storage.settings()
        let app = FrontObservation(bundleID: capture.source)
        guard allowedApplication(app, settings: current) else {
          health.policyRefusedCaptures += 1
          captures.removeFirst()
          continue
        }
        let result: ScreenCaptureResult
        if let run = capture.probeRunID, let attempt = capture.attemptID,
          let linked = storage as? AXProbeLinkedScreenWriter {
          result = try linked.appendScreenCapture(text: capture.text, at: capture.time, source: capture.source,
            documentKey: capture.documentKey, project: "", knownKeys: keyMemory.keys,
            probe: AXProbeLink(runID: run, attemptID: attempt))
        } else {
          result = try storage.appendScreenCapture(text: capture.text, at: capture.time,
            source: capture.source, documentKey: capture.documentKey, project: "", knownKeys: keyMemory.keys)
        }
        if let id = capture.attemptID { probeEvidence[id] = (result.evidenceID, capture.time, nil) }
        keyMemory.add(result.addedKeys, storedAt: capture.time, now: now)
        health.refusedCaptures += result.append.refused
        captures.removeFirst()
      } catch {
        failure(error)
        retryingWrites = true
        break
      }
    }
    if storage is AXProbeStore {
      var waiting: [(AXProbeReceipt, Int)] = []
      for (pair, generation) in probePending {
        guard generation == captureGeneration, !suspended, !stopped else { probePipeline?.discard(pair); continue }
        guard let linkage = probeEvidence[pair.attemptID] else {
          if captures.contains(where: { $0.attemptID == pair.attemptID }), now >= pair.time, now - pair.time <= 60 {
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
