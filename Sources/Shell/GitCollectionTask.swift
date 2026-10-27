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
  var afterLocationPrepared: ((inout GitPreparedRepositoryLocation) throws -> Void)?
  // Retained-occurrence backfill runs on the Git queue; log ingestion only enqueues it.
  private var backfillScheduled = false
  private var backfillQueue: [String] = []
  private var pendingSources: [String: LogPosition] = [:]
  private var recoveredSources = Set<String>()
  private var storedBackfillTime: Int?
  private var storedBackfillDone = false
  private var storedCursor: Int?
  private var checkpointCursor = 0
  static let backfillPageSize = 256
  private static let storedBackfill = "stored-events"
  // Test seams: page reads, retained event rows read and offered occurrences.
  var beforeBackfillPage: (() throws -> Void)?
  var backfillRows = 0
  var backfillOffers = 0
  /// Backfill passes that stopped on an error; each is retried at the next request or tick.
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
    guard let generation = try storage.gitObservationGeneration(now: now) else { return .other }
    let policy = try storage.gitPreparationPolicy()
    var prepared: GitPreparedRepositoryLocation
    do {
      prepared = try reader.withCancellation(cancellation: cancellation, shouldContinue: {
        !self.isStopped && (try? self.storage.gitPolicyAllowed(generation: generation, policy: policy, now: now)) == true
      }) { try reader.preparedLocation(folder.folder) }
    } catch let error as GitReadError {
      guard !isStopped, error != .cancelled else { return .other }
      try storage.rememberGitFolder(folder, location: nil, status: "failed", now: now, position: position, preparationGeneration: generation, preparationPolicy: policy)
      if let known = try storage.knownGitFolder(folder) { rawWorkingFolders[known.id] = folder.folder }
      return .other
    } catch {
      guard !isStopped else { return .other }
      throw error
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
  @discardableResult public func observe(_ events: [AgentLogEvent], position: LogPosition) throws -> GitObservationResult {
    let refusalRevision = storage.gitSecureInputDeferralRevision()
    // Per-record thread attribution takes precedence over a different header cursor.
    let folders = events.compactMap { event -> GitWorkingFolder? in
      guard let folder = event.workingFolder, !folder.isEmpty, let timestamp = event.timestamp else { return nil }
      return GitWorkingFolder(folder: folder, session: (event.explicitSession ?? event.session)?.storedKey ?? "", source: position.path,
        device: position.device, inode: position.inode, time: timestamp, tool: event.tool)
    }
    guard !isStopped else { return .deferred }
    guard !folders.isEmpty else { return .handled }
    guard try offer(folders, now: position.seenAt, fromStored: false, position: position,
      allowed: { !self.isStopped && !self.storage.gitSecureInputDeferred() }) else { return .deferred }
    // A denied admission can clear before the final reading; retain that batch.
    return storage.gitSecureInputDeferralRevision() != refusalRevision ? .deferred : .handled
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
      guard try allowed() else { return false }
      let admitted = try offerOne(group[latest]) == .touched
      guard try allowed() else { return false }
      if admitted { continue }
      for index in group.indices where index != latest {
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
  /// Unfinished work stays queued for the next request or maintenance tick.
  private func drainBackfill() {
    var unfinished: [(String, LogPosition?)] = []
    while true {
      schedulingLock.lock()
      guard !isStopped, !backfillQueue.isEmpty else {
        for (key, position) in unfinished where !backfillQueue.contains(key) {
          if let position, pendingSources[key] == nil { pendingSources[key] = position }
          backfillQueue.append(key)
        }
        backfillScheduled = false
        schedulingLock.unlock()
        return
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
      schedulingLock.unlock()
      if !finished { unfinished.append((key, position)) }
    }
  }
  /// Offers a source's retained occurrences above its durable mark, one page at a time.
  private func recover(_ position: LogPosition) throws -> Bool {
    try storage.withGitCancellation(cancellation) {
      guard try !storage.gitSourceRecoveryPending(position) else { return false }
      var cursor = try storage.gitBackfillProgress(position)
      while true {
        try beforeBackfillPage?()
        let page = try storage.gitBackfillPage(after: cursor, limit: Self.backfillPageSize, checkpoints: false, now: position.seenAt, source: position)
        countRows(page)
        guard let last = page.last else { return true }
        guard !page.recoveryPending, try offer(page.rows.map(\.folder), now: position.seenAt, fromStored: false, position: position,
          allowed: { !self.isStopped && !self.storage.gitSecureInputDeferred() }) else { return false }
        try storage.saveGitBackfillProgress(last, source: position)
        cursor = last.id
      }
    }
  }
  /// Stored occurrences above the durable mark, then every checkpoint. The mark advances
  /// only when no source is in metadata recovery; otherwise the pass repeats next tick.
  private func backfillStored(at now: Int) throws -> Bool {
    try storage.withGitCancellation(cancellation) {
      let allowed = { () throws -> Bool in try !self.isStopped && self.storage.gitRecordingAllowed(at: now) }
      var cursor = try storedCursor ?? storage.gitBackfillProgress(nil)
      var last: GitBackfillReceipt?
      while true {
        try beforeBackfillPage?()
        let page = try storage.gitBackfillPage(after: cursor, limit: Self.backfillPageSize, checkpoints: false, now: now)
        countRows(page)
        guard let pageLast = page.last else { break }
        guard try offer(page.rows.map(\.folder), now: now, fromStored: true, position: nil, allowed: allowed) else { return false }
        cursor = pageLast.id; last = pageLast; storedCursor = cursor
      }
      while true {
        try beforeBackfillPage?()
        let page = try storage.gitBackfillPage(after: checkpointCursor, limit: Self.backfillPageSize, checkpoints: true, now: now)
        guard let pageLast = page.last else { break }
        guard try offer(page.rows.map(\.folder), now: now, fromStored: true, position: nil, allowed: allowed) else { return false }
        checkpointCursor = pageLast.id
      }
      storedCursor = nil; checkpointCursor = 0
      guard try !storage.gitMetadataRecoveryPending() else { return false }
      if let last { try storage.saveGitBackfillProgress(last, source: nil) }
      return true
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
