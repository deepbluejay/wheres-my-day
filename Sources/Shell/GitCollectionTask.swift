import Core
import Foundation
import Inbound
import Storage

public enum GitObservationResult { case handled, deferred }

/// Shares the five-minute maintenance cadence, never the recorder/main-thread connection.
public final class GitCollectionTask {
  let storage: ActivityStorage
  let reader: GitRepositoryReader
  private let discoveryLock = NSRecursiveLock()
  private let historyQueue = DispatchQueue(label: "ActivityProbe.GitHistory", qos: .utility)
  private let schedulingLock = NSLock()
  private var scheduled = false
  private var requestedTime: Int?
  private let sliceDuration: TimeInterval
  private var pending: [Int: PendingGitRead] = [:]
  // Scheduling seams keep invented maintenance-overlap tests deterministic.
  var afterMetadataRead: (() throws -> Void)?
  var beforeMetadataRead: (() throws -> Void)?
  var afterCommitStarted: ((Int) throws -> Void)?
  var afterFileAppended: (() throws -> Void)?
  var beforeLocationPrepared: ((String) throws -> Void)?
  var afterLocationPrepared: ((inout GitPreparedRepositoryLocation) throws -> Void)?
  // Retained-occurrence backfill runs on the Git queue; log ingestion only enqueues it.
  private var backfillScheduled = false
  private var backfillQueue: [String] = []
  private var pendingSources: [String: LogPosition] = [:]
  private var recoveredSources = Set<String>()
  private var storedBackfillTime: Int?
  private var storedBackfillDone = false
  private var storedCursor: Int?
  private var storedLast: GitBackfillReceipt?
  private var checkpointCursor = 0
  private var checkpointSince: Int?
  private var checkpointStart = 0
  // Loaded once per process on the Git queue; only that queue reads or extends it.
  private var finishedReceipts: Set<String>?
  // Raw cwd occurrences handed off after an append, in memory only, offered before backfill.
  private var liveQueue: [LiveBatch] = []
  private var liveOccurrences = 0
  static let liveOccurrenceLimit = 50_000
  static let backfillRetries = 3
  static let backfillPageSize = 256
  private static let storedBackfill = "stored-events"
  // Test seams: page reads, retained event and checkpoint rows read, offered occurrences,
  // and source recoveries that reached the database.
  var beforeBackfillPage: (() throws -> Void)?
  var backfillRows = 0
  var backfillOffers = 0
  var checkpointRows = 0
  var sourceReads = 0
  /// Backfill passes that stopped on an error; each is retried in the same drain, then at the next request or tick.
  public private(set) var backfillFailures = 0
  private var rawDirectories: [Int: String] = [:]
  private var rawWorkingFolders: [Int: String] = [:]
  private let cancellation = GitTaskCancellation()
  private let scratchParent: URL
  private let scratchRoot: URL
  public init(storage: ActivityStorage, reader: GitRepositoryReader = GitRepositoryReader(), sliceDuration: TimeInterval = 0.25,
    secureInput: @escaping () -> Bool? = { MacSecureInputSource().secureInput().value },
    scratchDirectory: URL = FileManager.default.temporaryDirectory) {
    scratchParent = scratchDirectory
    scratchRoot = scratchDirectory.appendingPathComponent("activityprobe-git-task-" + UUID().uuidString)
    storage.setGitSecureInput(secureInput)
    self.storage = storage; self.reader = reader; self.sliceDuration = sliceDuration
    historyQueue.async { [weak self] in
      guard let self, !self.isStopped else { return }
      try? self.storage.withGitCancellation(self.cancellation) {
        try self.storage.cleanGitCancelledWork()
        try GitScratchCleanup.recover(in: self.scratchParent, cancellation: self.cancellation)
      }
    }
  }
  deinit { GitScratchCleanup.discard(scratchRoot, cancellation: cancellation) }
  public var maintenanceTask: RecorderMaintenanceTask {
    RecorderMaintenanceTask(name: "git-history", cancel: { self.stop() }, finish: { self.finish($0) }) { time in
      try self.discover(at: time)
      self.scheduleHistory(at: time)
    }
  }
  public func stop() {
    if cancellation.cancel() {
      reader.cancel()
      try? storage.cancelGitStaging(cancellation)
    }
  }
  public func finish(_ completion: @escaping () -> Void) {
    historyQueue.async {
      // Releasing many disposable directories must not delay the quit callback.
      // Each directory has its own bounded disposal/recovery receipt.
      self.discardPending()
      try? self.storage.withGitCancellation(self.cancellation) { try self.storage.cleanGitCancelledWork() }
      completion()
    }
  }
  private func discardPending() {
    // One durable root receipt survives quit even if background reference release
    // has not run yet. These spools contain machine hashes, never user text.
    GitScratchCleanup.discard(scratchRoot, cancellation: cancellation)
    let discarded = pending
    pending = [:]
    DispatchQueue.global(qos: .utility).async { _ = discarded.count }
  }
  private var isStopped: Bool {
    cancellation.isCancelled
  }
  private func readAllowed(at now: Int) -> Bool {
    !isStopped && (try? storage.gitRecordingAllowed(at: now)) == true
  }
  public func observe(_ folder: GitWorkingFolder, now: Int, fromStored: Bool = false, position: LogPosition? = nil) throws {
    _ = try observeOutcome(folder, now: now, fromStored: fromStored, position: position)
  }
  private enum Outcome { case touched, registered, other }
  @discardableResult private func observeOutcome(_ folder: GitWorkingFolder, now: Int, fromStored: Bool, position: LogPosition?) throws -> Outcome {
    try storage.withGitCancellation(cancellation) {
      try observeAllowed(folder, now: now, fromStored: fromStored, position: position)
    }
  }
  @discardableResult private func observeAllowed(_ folder: GitWorkingFolder, now: Int, fromStored: Bool, position: LogPosition?) throws -> Outcome {
    discoveryLock.lock(); defer { discoveryLock.unlock() }
    guard !isStopped, folder.folder.hasPrefix("/"), try storage.validateGitObservation(folder, now: now, position: position) else { return .other }
    if let known = try storage.knownGitFolder(folder, allowMaskedMatch: fromStored), let repo = known.repo {
      let touched = try storage.touchGitFolder(folder, id: known.id, now: now, position: position)
      if FileManager.default.fileExists(atPath: folder.folder) {
        rawWorkingFolders[known.id] = folder.folder
        if rawDirectories[repo] == nil, let location = try? reader.withCancellation(cancellation: cancellation, shouldContinue: { self.readAllowed(at: now) }, {
          try reader.directoryLocation(folder.folder)
        }) {
          rawDirectories[repo] = location.commonDirectory
          try storage.gitReopenBlocked(repo: repo, blocked: false, now: now)
        }
      }
      return touched ? .touched : .other
    }
    guard try storage.gitShouldResolve(folder, now: now, position: position) else { return .other }
    guard FileManager.default.fileExists(atPath: folder.folder) else {
      try storage.rememberGitFolder(folder, location: nil, status: "missing", now: now, position: position)
      if let known = try storage.knownGitFolder(folder) { rawWorkingFolders[known.id] = folder.folder }
      return .other
    }
    let previous = try storage.gitUnlinkedFolderState(folder)
    // No Git child for a folder outside every repository: it is not a read failure, and a
    // later git init is still found by this path check at the next occurrence.
    if Self.outsideRepository(folder.folder) {
      if previous?.status != "unversioned" {
        try storage.rememberGitFolder(folder, location: nil, status: "unversioned", now: now, position: position)
      }
      if let known = try storage.knownGitFolder(folder) { rawWorkingFolders[known.id] = folder.folder }
      return .other
    }
    // A real read failure is retried after 5 minutes, doubling up to once a day.
    if let previous, previous.status == "failed", now >= previous.attempt,
      now - previous.attempt < Self.retryDelay(failures: previous.failures) { return .other }
    guard let generation = try storage.gitObservationGeneration(now: now) else { return .other }
    let policy = try storage.gitPreparationPolicy()
    var prepared: GitPreparedRepositoryLocation
    do {
      prepared = try reader.withCancellation(cancellation: cancellation, shouldContinue: {
        !self.isStopped && (try? self.storage.gitPolicyAllowed(generation: generation, policy: policy, now: now)) == true
      }) {
        try beforeLocationPrepared?(folder.folder)
        return try reader.preparedLocation(folder.folder)
      }
    } catch {
      // Any read error, such as a path that cannot be resolved, is this folder's failure
      // with the usual backoff, so it cannot stop the batch or hold a backfill mark.
      guard !isStopped, (error as? GitReadError) != .cancelled else { return .other }
      try storage.rememberGitFolder(folder, location: nil, status: "failed", now: now, position: position, preparationGeneration: generation, preparationPolicy: policy)
      if let known = try storage.knownGitFolder(folder) { rawWorkingFolders[known.id] = folder.folder }
      return .other
    }
    do {
      try afterLocationPrepared?(&prepared)
      let location = prepared.location
      // Publication failures belong to storage, and must never create a failed Git discovery.
      try storage.rememberGitFolder(folder, location: location, status: "ready", now: now, position: position,
        preparedBranch: prepared.branch, preparationGeneration: generation, preparationPolicy: policy)
      if let known = try storage.knownGitFolder(folder), let repo = known.repo {
        rawDirectories[repo] = location.commonDirectory
        try storage.gitReopenBlocked(repo: repo, blocked: false, now: now)
        rawWorkingFolders[known.id] = folder.folder
        return .registered
      }
      return .other
    } catch {
      guard !isStopped else { return .other }
      throw error
    }
  }
  private static func liveFolders(_ events: [AgentLogEvent], position: LogPosition) -> [GitWorkingFolder] {
    // Per-record thread attribution takes precedence over a different header cursor.
    events.compactMap { event -> GitWorkingFolder? in
      guard let folder = event.workingFolder, !folder.isEmpty, let timestamp = event.timestamp else { return nil }
      return GitWorkingFolder(folder: folder, session: (event.explicitSession ?? event.session)?.storedKey ?? "", source: position.path,
        device: position.device, inode: position.inode, time: timestamp, tool: event.tool)
    }
  }
  /// The synchronous form of a live hand-off, on the caller's thread.
  /// Git finds a repository only through a .git entry in the folder or a parent, or a bare
  /// repository the folder lies in. Without either, rev-parse can only say "not a repository".
  /// Git walks the physical path, so a link into a repository folder is walked both ways;
  /// when the two walks disagree the Git child decides.
  static func outsideRepository(_ folder: String) -> Bool {
    let url = URL(fileURLWithPath: folder, isDirectory: true)
    return outsideRepository(walking: url.standardizedFileURL) && outsideRepository(walking: url.resolvingSymlinksInPath())
  }
  private static func outsideRepository(walking start: URL) -> Bool {
    var url = start
    let files = FileManager.default
    while true {
      if files.fileExists(atPath: url.appendingPathComponent(".git").path) { return false }
      if ["HEAD", "objects", "refs"].allSatisfy({ files.fileExists(atPath: url.appendingPathComponent($0).path) }) { return false }
      if url.path == "/" { return true }
      url.deleteLastPathComponent()
    }
  }
  static func retryDelay(failures: Int) -> Int { min(86_400, 300 << min(max(failures - 1, 0), 9)) }
  @discardableResult public func observe(_ events: [AgentLogEvent], position: LogPosition) throws -> GitObservationResult {
    try observeLive(Self.liveFolders(events, position: position), position: position)
  }
  private func observeLive(_ folders: [GitWorkingFolder], position: LogPosition) throws -> GitObservationResult {
    let refusalRevision = storage.gitSecureInputDeferralRevision()
    guard !isStopped else { return .deferred }
    guard !folders.isEmpty else { return .handled }
    guard try offer(folders, now: position.seenAt, fromStored: false, position: position,
      allowed: { !self.isStopped && !self.storage.gitSecureInputDeferred() }) else { return .deferred }
    // A denied admission can clear before the final reading; retain that batch.
    return storage.gitSecureInputDeferralRevision() != refusalRevision ? .deferred : .handled
  }
  private struct LiveBatch {
    let folders: [GitWorkingFolder], position: LogPosition, deferred: (_ failed: Bool) -> Void
  }
  /// Called after the append. The batch's raw cwd occurrences wait in memory for the Git
  /// queue, so the agent-log thread never checks the file system or starts Git. Over the
  /// bound, after a deferral or error, or after a crash, the source's masked stored
  /// occurrences are recovered instead. `deferred` runs once for such a batch.
  public func handOff(_ events: [AgentLogEvent], position: LogPosition, deferred: @escaping (_ failed: Bool) -> Void) {
    let folders = Self.liveFolders(events, position: position)
    guard !folders.isEmpty else { requestRecovery(position); return }
    schedulingLock.lock()
    let admitted = !isStopped && liveOccurrences + folders.count <= Self.liveOccurrenceLimit
    if admitted {
      liveQueue.append(LiveBatch(folders: folders, position: position, deferred: deferred))
      liveOccurrences += folders.count
    }
    schedulingLock.unlock()
    if !admitted { deferred(false) }
    requestRecovery(position, afterDeferral: !admitted)
  }
  private func offerLive(_ batch: LiveBatch) {
    var failed = false
    do { if try observeLive(batch.folders, position: batch.position) == .handled { return } }
    catch { failed = true }
    batch.deferred(failed)
    requestRecovery(batch.position, afterDeferral: true)
  }
  private struct OccurrenceKey: Hashable {
    let tool: String, folder: String, session: String, source: String, identity: String?, device: Int, inode: Int
    init(_ folder: GitWorkingFolder) {
      tool = folder.tool?.rawValue ?? ""; self.folder = folder.folder; session = folder.session; source = folder.source
      identity = folder.sourceIdentity?.storedKey; device = folder.device; inode = folder.inode
    }
  }
  /// Offers occurrences in order with the same effect as one observation each.
  /// Equal occurrences of a linked folder only move last_seen forward, so one admitted
  /// touch at the latest time stands for the earlier ones; a refused probe falls back
  /// to the original order. An unlinked folder already attempted at `now` is refused
  /// as known by the gate, and an unattributable source is refused at any time, so
  /// their later equal occurrences are skipped.
  private func offer(_ folders: [GitWorkingFolder], now: Int, fromStored: Bool, position: LogPosition?, allowed: () throws -> Bool) throws -> Bool {
    var linked: [OccurrenceKey: [GitWorkingFolder]] = [:], order: [OccurrenceKey] = []
    var offered = Set<OccurrenceKey>(), unattributable = Set<OccurrenceKey>()
    func offerOne(_ folder: GitWorkingFolder) throws -> Outcome {
      schedulingLock.lock(); backfillOffers += 1; schedulingLock.unlock()
      return try observeOutcome(folder, now: now, fromStored: fromStored, position: position)
    }
    for folder in folders where folder.folder.hasPrefix("/") {
      let key = OccurrenceKey(folder)
      if linked[key] != nil { linked[key]!.append(folder); continue }
      if unattributable.contains(key) { continue }
      guard try allowed() else { return false }
      let state = try storage.withGitCancellation(cancellation) { try storage.gitFolderOccurrence(folder, allowMaskedMatch: fromStored) }
      if state.linked { linked[key] = [folder]; order.append(key); continue }
      if offered.contains(key), state.attempt == now { continue }
      if try storage.withGitCancellation(cancellation, { try storage.gitOccurrenceUnattributable(folder, position: position) }) {
        unattributable.insert(key); continue
      }
      _ = try offerOne(folder)
      offered.insert(key)
      guard try allowed() else { return false }
    }
    for key in order {
      let group = linked[key]!
      let latest = group.indices.max { group[$0].time < group[$1].time }!
      var rest = group.indices.sorted { (group[$0].time, $0) < (group[$1].time, $1) }
      guard try allowed() else { return false }
      // A concurrent forget can unlink the folder after its first occurrence. Its group is
      // then offered in time order, so a re-registered row starts at its earliest time.
      let state = try storage.withGitCancellation(cancellation) { try storage.gitFolderOccurrence(group[latest], allowMaskedMatch: fromStored) }
      if state.linked {
        let admitted = try offerOne(group[latest]) == .touched
        guard try allowed() else { return false }
        if admitted { continue }
        rest.removeAll { $0 == latest }
        // Refused because the folder was unlinked meanwhile: the re-registered row must
        // still reach the latest time, so that occurrence is offered again, last.
        let after = try storage.withGitCancellation(cancellation) { try storage.gitFolderOccurrence(group[latest], allowMaskedMatch: fromStored) }
        if !after.linked { rest.append(latest) }
      }
      for index in rest {
        guard try allowed() else { return false }
        _ = try offerOne(group[index])
        guard try allowed() else { return false }
      }
    }
    return true
  }
  /// Called after the agent-log append, never before it. A source is offered once per
  /// process, and again after Secure Input deferred its live observation.
  public func requestRecovery(_ position: LogPosition, afterDeferral: Bool = false) {
    guard position.offset > 0 else { return }
    let key = "\(position.device):\(position.inode):" + position.path
    schedulingLock.lock()
    if afterDeferral { recoveredSources.remove(key) }
    guard !recoveredSources.contains(key) else { schedulingLock.unlock(); return }
    if pendingSources.updateValue(position, forKey: key) == nil, !backfillQueue.contains(key) { backfillQueue.append(key) }
    schedulingLock.unlock()
    scheduleBackfill()
  }
  private func requestStoredBackfill(at now: Int) {
    schedulingLock.lock()
    if !storedBackfillDone {
      storedBackfillTime = now
      if !backfillQueue.contains(Self.storedBackfill) { backfillQueue.append(Self.storedBackfill) }
    }
    schedulingLock.unlock()
  }
  private func scheduleBackfill() {
    schedulingLock.lock()
    guard !isStopped, !backfillScheduled, !backfillQueue.isEmpty else { schedulingLock.unlock(); return }
    backfillScheduled = true
    schedulingLock.unlock()
    historyQueue.async { self.drainBackfill() }
  }
  /// Live hand-offs go first. A pass that stops on an error, such as a busy writer, is
  /// retried in the same drain after a short pause; other unfinished work stays queued
  /// for the next request or maintenance tick.
  private func drainBackfill() {
    var unfinished: [(String, LogPosition?)] = [], attempts: [String: Int] = [:]
    while true {
      schedulingLock.lock()
      guard !isStopped, !liveQueue.isEmpty || !backfillQueue.isEmpty else {
        if isStopped { liveQueue = []; liveOccurrences = 0 }
        for (key, position) in unfinished where !backfillQueue.contains(key) {
          if let position, pendingSources[key] == nil { pendingSources[key] = position }
          backfillQueue.append(key)
        }
        backfillScheduled = false
        schedulingLock.unlock()
        return
      }
      if !liveQueue.isEmpty {
        let live = liveQueue.removeFirst()
        liveOccurrences -= live.folders.count
        schedulingLock.unlock()
        offerLive(live)
        continue
      }
      let key = backfillQueue.removeFirst()
      let position = pendingSources.removeValue(forKey: key)
      let storedTime = key == Self.storedBackfill ? storedBackfillTime : nil
      schedulingLock.unlock()
      var finished = false, failed = false
      do {
        if let position { finished = try recover(position) }
        else if let storedTime { finished = try backfillStored(at: storedTime) }
        else { continue }
      } catch { failed = !isStopped }
      schedulingLock.lock()
      if failed { backfillFailures += 1 }
      if finished, position != nil { recoveredSources.insert(key) }
      if finished, position == nil { storedBackfillDone = true }
      let retry = failed && attempts[key, default: 0] < Self.backfillRetries
      if retry {
        attempts[key, default: 0] += 1
        if let position, pendingSources[key] == nil { pendingSources[key] = position }
        if !backfillQueue.contains(key) { backfillQueue.append(key) }
      }
      schedulingLock.unlock()
      if retry { Thread.sleep(forTimeInterval: 0.05 * Double(attempts[key]!)); continue }
      if !finished { unfinished.append((key, position)) }
    }
  }
  /// A page offered under one privacy policy, read before the page. The mark covers only
  /// pages that policy still allows after the offer: recording off or paused at `now`, a
  /// forget covering `now`, or a policy or generation change leaves the page unmarked.
  private func pagePolicy(now: Int) throws -> () throws -> Bool {
    let policy = try storage.gitPreparationPolicy()
    return { try !self.isStopped && self.storage.gitPolicyAllowed(policy, now: now) }
  }
  /// Offers a source's retained occurrences above its durable mark, one page at a time.
  /// A source finished at its current offset is skipped without reading the database.
  private func recover(_ position: LogPosition) throws -> Bool {
    try storage.withGitCancellation(cancellation) {
      let receipt = try storage.gitBackfillFinishedKey(position)
      if finishedReceipts == nil { finishedReceipts = try storage.gitBackfillFinishedReceipts() }
      if let receipt, finishedReceipts!.contains(receipt) { return true }
      schedulingLock.lock(); sourceReads += 1; schedulingLock.unlock()
      guard try !storage.gitSourceRecoveryPending(position) else { return false }
      var cursor = try storage.gitBackfillProgress(position)
      while true {
        try beforeBackfillPage?()
        let allowed = try pagePolicy(now: position.seenAt)
        guard try allowed() else { return false }
        let page = try storage.gitBackfillPage(after: cursor, limit: Self.backfillPageSize, checkpoints: false, now: position.seenAt, source: position)
        countRows(page)
        guard let last = page.last else {
          if let receipt { try storage.saveGitBackfillFinished(position); finishedReceipts!.insert(receipt) }
          return true
        }
        guard !page.recoveryPending, try offer(page.rows.map(\.folder), now: position.seenAt, fromStored: false, position: position,
          allowed: allowed), try allowed() else { return false }
        try storage.saveGitBackfillProgress(last, source: position)
        cursor = last.id
      }
    }
  }
  /// Stored occurrences above the durable mark, then checkpoints written since the last
  /// complete pass. Rows whose source is in metadata recovery are not offered, and neither
  /// mark waits for them; while any source is in recovery the pass repeats next tick, from
  /// the marks. A checkpoint leaves recovery only by being written again, above the pass's
  /// floor, so that repeat reads it. Its retained occurrences were all stored before
  /// recovery began (a deferred read appends nothing); that read's hand-off requests the
  /// source's own recovery, which offers them above the source's mark. One row stuck in
  /// recovery, such as a deleted log's, so costs a repeat that reads only what changed,
  /// not every event and checkpoint.
  private func backfillStored(at now: Int) throws -> Bool {
    try storage.withGitCancellation(cancellation) {
      var cursor = try storedCursor ?? storage.gitBackfillProgress(nil)
      while true {
        try beforeBackfillPage?()
        let allowed = try pagePolicy(now: now)
        guard try allowed() else { return false }
        let page = try storage.gitBackfillPage(after: cursor, limit: Self.backfillPageSize, checkpoints: false, now: now)
        countRows(page)
        guard let pageLast = page.last else { break }
        guard try offer(page.rows.map(\.folder), now: now, fromStored: true, position: nil, allowed: allowed), try allowed() else { return false }
        cursor = pageLast.id; storedLast = pageLast; storedCursor = cursor
      }
      // A clock set back below the mark rereads every checkpoint once instead of skipping some.
      // A resumed pass keeps the time and threshold of the attempt that started at cursor 0.
      if checkpointSince == nil {
        let mark = try storage.gitCheckpointBackfillMark()
        try storage.startGitCheckpointPass(now)
        checkpointSince = mark > now ? Int.min : mark; checkpointStart = now
      }
      let since = checkpointSince!, start = checkpointStart
      while true {
        try beforeBackfillPage?()
        let allowed = try pagePolicy(now: now)
        guard try allowed() else { return false }
        let page = try storage.gitBackfillPage(after: checkpointCursor, limit: Self.backfillPageSize, checkpoints: true, now: now, since: since)
        schedulingLock.lock(); checkpointRows += page.rows.count; schedulingLock.unlock()
        guard let pageLast = page.last else { break }
        guard try offer(page.rows.map(\.folder), now: now, fromStored: true, position: nil, allowed: allowed), try allowed() else { return false }
        checkpointCursor = pageLast.id
      }
      let last = storedLast
      storedCursor = nil; storedLast = nil; checkpointCursor = 0; checkpointSince = nil
      if let last { try storage.saveGitBackfillProgress(last, source: nil) }
      // A checkpoint written after the pass started has a seen_ts above `start`, so every
      // checkpoint at or below it was read. Later ones are read again.
      if start > since { try storage.saveGitCheckpointBackfillMark(start) }
      return try !storage.gitMetadataRecoveryPending()
    }
  }
  private func countRows(_ page: GitBackfillPage) {
    schedulingLock.lock(); backfillRows += page.rows.count; schedulingLock.unlock()
  }
  /// Test seams: queue the stored pass as discovery does, and wait for the Git queue.
  func backfill(at now: Int) { requestStoredBackfill(at: now); scheduleBackfill() }
  func waitForBackfill() { historyQueue.sync {} }
  public func scan(at now: Int) throws {
    do {
      try discover(at: now)
      try historyQueue.sync { try scanHistory(at: now) }
    } catch {
      guard !isStopped else { return }
      throw error
    }
  }
  /// Only discovery shares the log-maintenance queue; history cannot delay later cwd receipts.
  private func scheduleHistory(at now: Int) {
    guard !isStopped else { return }
    schedulingLock.lock()
    requestedTime = now
    guard !scheduled else { schedulingLock.unlock(); return }
    scheduled = true
    schedulingLock.unlock()
    historyQueue.async {
      while true {
        self.schedulingLock.lock()
        guard !self.isStopped, let time = self.requestedTime else {
          self.scheduled = false; self.schedulingLock.unlock(); return
        }
        self.requestedTime = nil
        self.schedulingLock.unlock()
        try? self.scanHistory(at: time)
      }
    }
  }
  private func discover(at now: Int) throws {
    defer { scheduleBackfill() }
    try storage.withGitCancellation(cancellation) { try discoverAllowed(at: now) }
  }
  private func discoverAllowed(at now: Int) throws {
    discoveryLock.lock(); defer { discoveryLock.unlock() }
    guard !isStopped else { return }
    try storage.cleanGitCancelledWork()
    try GitScratchCleanup.recover(in: scratchParent, cancellation: cancellation)
    guard try storage.gitRecordingAllowed(at: now) else { return }
    rawDirectories = try rawDirectories.filter { try cancellation.check(); return try storage.gitRepositoryExists($0.key) }
    rawWorkingFolders = try rawWorkingFolders.filter { try cancellation.check(); return try storage.gitFolderExists($0.key) }
    requestStoredBackfill(at: now)
    var folderCursor = 0
    while let (id, folder, repo) = try storage.nextGitFolder(after: folderCursor) {
      guard !isStopped, try storage.gitRecordingAllowed(at: now) else { return }
      folderCursor = id
      guard try storage.validateGitObservation(folder, now: now) else { continue }
      var observation = folder
      observation.folder = rawWorkingFolders[id] ?? folder.folder
      let exists = FileManager.default.fileExists(atPath: observation.folder)
      try storage.gitFolderPresence(id: id, exists: exists, now: now)
      if repo == nil && exists { try observe(observation, now: now) }
    }
  }
  /// Each repository yields after a time slice, retaining its spool offset and ref frontier.
  /// Completed commit rows are the durable restart cursor; ref tips advance only after EOF.
  private func scanHistory(at now: Int) throws {
    guard !isStopped else { return }
    try storage.withGitCancellation(cancellation) {
      try reader.withCancellation(cancellation: cancellation, shouldContinue: { self.readAllowed(at: now) }) { try scanHistoryAllowed(at: now) }
    }
  }
  private func scanHistoryAllowed(at now: Int) throws {
    var completed = Set<Int>()
    while !isStopped, try storage.gitRecordingAllowed(at: now) {
      var cursor = 0, advanced = false
      while !isStopped, let repo = try storage.nextGitRepository(after: cursor) {
        cursor = repo.id
        if completed.contains(repo.id) { continue }
        guard !isStopped, try storage.gitRecordingAllowed(at: now) else { return }
        advanced = true
        do {
          let read: PendingGitRead
          if let existing = pending[repo.id] { read = existing }
          else { read = try prepare(repo, now: now); pending[repo.id] = read }
          if try readSlice(read, repo: repo.id, now: now) {
            try storage.finishGitRead(repo: repo.id, now: now, outcome: .accounted)
            pending.removeValue(forKey: repo.id); completed.insert(repo.id)
          }
        } catch {
          pending.removeValue(forKey: repo.id); completed.insert(repo.id)
          // Only an actual Git read error counts as a read failure. Storage admission,
          // retention and cancellation interruptions still discard the pending frontier.
          let outcome: GitReadFinish = !isStopped && error is GitReadError && (error as? GitReadError) != .cancelled ? .nativeFailure : .interrupted
          try storage.finishGitRead(repo: repo.id, now: now, outcome: outcome)
        }
      }
      guard !isStopped else { discardPending(); return }
      pending = try pending.filter { try cancellation.check(); return try storage.gitRepositoryExists($0.key) }
      if !advanced { return }
    }
  }
  private func prepare(_ repo: StoredGitRepository, now: Int) throws -> PendingGitRead {
    guard let generation = try storage.gitPreparationGeneration(repo: repo.id, now: now) else { throw GitReadError.cancelled }
    let policy = try storage.gitPreparationPolicy()
    return try reader.withCancellation(cancellation: cancellation, shouldContinue: {
      !self.isStopped && (try? self.storage.gitPreparationAllowed(repo: repo.id, hash: "", generation: generation, policy: policy, now: now)) == true
    }) { try prepareAllowed(repo, now: now) }
  }
  private func prepareAllowed(_ repo: StoredGitRepository, now: Int) throws -> PendingGitRead {
    try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let scratch = scratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var transferred = false
    defer { if !transferred { GitScratchCleanup.discard(scratch, cancellation: cancellation) } }
    discoveryLock.lock()
    let raw = rawDirectories[repo.id]
    discoveryLock.unlock()
    try storage.gitReopenBlocked(repo: repo.id, blocked: raw == nil && repo.needsRawDirectory, now: now)
    guard raw != nil || !repo.needsRawDirectory else { throw GitReadError.failed }
    let directory = raw ?? repo.directory
    let exclusions = scratch.appendingPathComponent("tips")
    let previous = scratch.appendingPathComponent("previous-tips")
    let hashes = scratch.appendingPathComponent("hashes")
    FileManager.default.createFile(atPath: exclusions.path, contents: nil, attributes: [.posixPermissions: 0o600])
    FileManager.default.createFile(atPath: hashes.path, contents: nil, attributes: [.posixPermissions: 0o600])
    FileManager.default.createFile(atPath: previous.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let input = try FileHandle(forWritingTo: exclusions)
    defer { try? input.close() }
    let saved = try FileHandle(forWritingTo: previous)
    defer { try? saved.close() }
    try storage.prepareGitRefs(repo: repo.id, to: saved, now: now)
    try saved.close()
    // Rewritten refs can lose their old objects to the owner's GC. Missing tips are not exclusions.
    try reader.tokens(at: directory, ["cat-file", "--batch-check=%(objectname) %(objecttype)"], separator: 10, input: previous) { line in
      let fields = line.split(separator: " ")
      guard fields.count == 2, GitRepositoryReader.validHash(String(fields[0])) else { throw GitReadError.malformed }
      if fields[1] != "missing" { try input.write(contentsOf: Data(("^" + String(fields[0]) + "\n").utf8)) }
    }
    try reader.preparedRefs(at: directory) { name, tip, identity in
      try storage.stageGitRef(repo: repo.id, name: name, identity: identity, tip: tip)
      try input.write(contentsOf: Data((tip + "\n").utf8))
    }
    try reader.preparedWorktreeHeads(at: directory) { name, tip, identity in
      try storage.stageGitRef(repo: repo.id, name: name, identity: identity, tip: tip)
      try input.write(contentsOf: Data((tip + "\n").utf8))
    }
    try input.close()
    let output = try FileHandle(forWritingTo: hashes)
    defer { try? output.close() }
    let cutoff = try now - storage.settings().promptRetentionDays * 86400
    // since-as-filter traverses through timestamp-skewed parents instead of cutting the graph early.
    try reader.run(at: directory, ["rev-list", "--all", "--since-as-filter=@\(cutoff)", "--stdin"], input: exclusions) {
      try output.write(contentsOf: $0)
    }
    try output.close()
    let result = try PendingGitRead(scratch: scratch, directory: directory, hashes: hashes, cancellation: cancellation)
    transferred = true
    return result
  }
  private func readSlice(_ read: PendingGitRead, repo: Int, now: Int) throws -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + sliceDuration
    let cursor = try GitHashCursor(read)
    repeat {
      try cancellation.check()
      guard try storage.gitRecordingAllowed(at: now), try storage.gitRepositoryExists(repo) else { return false }
      guard let hash = try cursor.nextHash() else { return true }
      guard GitRepositoryReader.validHash(hash) else { throw GitReadError.malformed }
      if try !storage.gitCommitKnown(repo: repo, hash: hash) {
        try readCommit(read, repo: repo, hash: hash, now: now)
      }
    } while ProcessInfo.processInfo.systemUptime < deadline
    return false
  }
  private func readCommit(_ read: PendingGitRead, repo: Int, hash: String, now: Int) throws {
    guard let generation = try storage.gitPreparationGeneration(repo: repo, now: now) else { throw GitReadError.cancelled }
    let policy = try storage.gitPreparationPolicy()
    try reader.withCancellation(cancellation: cancellation, shouldContinue: {
      !self.isStopped && (try? self.storage.gitPreparationAllowed(repo: repo, hash: hash, generation: generation, policy: policy, now: now)) == true
    }) {
      try beforeMetadataRead?()
      let commit = try reader.preparedCommit(at: read.directory, hash: hash)
      try afterMetadataRead?()
      if let id = try storage.beginGitCommit(repo: repo, prepared: commit, generation: generation, now: now, preparationPolicy: policy) {
        defer { try? storage.abandonGitCommit(id) }
        try afterCommitStarted?(id)
        do {
          try reader.preparedFiles(at: read.directory, hash: hash) {
            try storage.appendGitFile($0, commit: id, now: now)
            try afterFileAppended?()
          }
          try reader.preparedRefs(at: read.directory, contains: hash) { name, _, identity in try storage.appendGitCommitRef(name, identity: identity, commit: id, now: now) }
          try reader.preparedWorktreeHeads(at: read.directory, contains: hash) { name, _, identity in
            try storage.appendGitCommitRef(name, identity: identity, commit: id, now: now)
          }
        } catch {
          guard try storage.gitHashForgotten(hash) else { throw error }
        }
        try cancellation.check()
        guard try storage.finishGitCommit(id, now: now) != .retry else { throw StorageError.busy("Git commit publication interrupted") }
      } else if try storage.gitReadNeedsRetry(repo: repo) {
        throw StorageError.busy("Git commit admission interrupted")
      }
    }
  }
}

private final class PendingGitRead {
  let scratch: URL
  let directory: String
  let hashes: URL
  var offset: UInt64 = 0
  let cancellation: GitTaskCancellation
  init(scratch: URL, directory: String, hashes: URL, cancellation: GitTaskCancellation) throws {
    self.cancellation = cancellation
    self.scratch = scratch; self.directory = directory
    self.hashes = hashes
  }
  deinit { GitScratchCleanup.discard(scratch, cancellation: cancellation) }
}

/// A yielded repository retains only a file offset, not an open descriptor or output buffer.
private final class GitHashCursor {
  let read: PendingGitRead
  let file: FileHandle
  private var buffer = Data()
  init(_ read: PendingGitRead) throws {
    self.read = read
    file = try FileHandle(forReadingFrom: read.hashes)
    try file.seek(toOffset: read.offset)
  }
  deinit { try? file.close() }
  func nextHash() throws -> String? {
    while true {
      if let newline = buffer.firstIndex(of: 10) {
        let hash = String(decoding: buffer[..<newline], as: UTF8.self)
        buffer.removeSubrange(...newline)
        read.offset += UInt64(hash.utf8.count + 1)
        return hash
      }
      guard let data = try file.read(upToCount: 65536), !data.isEmpty else {
        guard buffer.isEmpty else { throw GitReadError.malformed }
        return nil
      }
      guard buffer.count <= 65 else { throw GitReadError.malformed }
      buffer.append(data)
    }
  }
}
