import Core
import Foundation

// Git publication protocol
//
// Discovery/repository registration, commit parents/children/text chunks, and
// frontier rows/chunks/certification all enter publishGit. Prepared masked text
// is not permission. Admission reads current privacy inside BEGIN IMMEDIATE,
// after writer admission, for every durable unit, including incomplete content.
//
// Allowed transitions: prepared -> admitted/refused/interrupted; admitted ->
// complete/refused/interrupted; interrupted -> uncertified debt -> fresh retry.
// Complete/refused outcomes account for traversal. Expiry accounts only for the
// current traversal; a wider retention window may prepare that identity again.
// Interrupted work is retryable; persisted incomplete parents/inactive frontiers
// are uncertified debt after cancellation or a crash. Only complete children or
// explicit terminal refusals account for a commit. Only accounted-for traversal
// may certify the frontier. The publishing scope must match captured producer
// cancellation ownership, and cancellation/certification serialize at COMMIT.
//
// Operation facts: discovery carries original cwd time, tool/session/source,
// source revision and immutable policy; commit units resolve their immutable
// repo/hash/both-native-time receipt; frontier units resolve original read time,
// policy, pending token and exact parent/count ownership. Diagnostics carry IDs.
//
// Current recording/pause, Secure Input, tool-qualified source provenance,
// own-app/folder exclusion, historical recording/pause at both native times,
// the durable
// retention clock, tombstones, forget revision and recording generation form
// the authority. Missing receipts/history never grant permission. Forget marks
// identity before erasure; stale preparation cannot resurrect erased content.
// Retention expiry and interruption never create permanent refusal markers.
//
// Schema/adoption preserves the additive schema contract. Privacy erasure,
// revocation and bounded debt disposal only remove content or invalidate authority.
// TEMP holds masked disposable refs, never a certified durable frontier.
// Mutation inventory tests enumerate those exceptions as well as publications.
// General app/folder-list mapping for imported CLI logs remains a product
// question; a known tool-qualified non-owned source is the permitted provenance.

enum GitWorkState: Equatable {
  case prepared, admitted, complete, refused, interrupted, uncertifiedDebt
}

struct GitCommitPublication {
  let repo: Int
  let hash: String
  let generation: Int
  let policy: GitPreparationPolicy
  let authorTime: Int
  let commitTime: Int
  var state: GitWorkState = .prepared
  var cancellation: GitTaskCancellation?
}

struct GitFolderPreparation {
  var state: GitWorkState = .prepared
  var cancellation: GitTaskCancellation?
}

struct GitReadPublication {
  let policy: GitPreparationPolicy
  let preparedAt: Int
  var state: GitWorkState = .prepared
  var cancellation: GitTaskCancellation?
}

struct GitDiscoveryPublication {
  enum Phase { case touchValidation, touch(Int), register(String), branch(Int), complete(Int) }
  let folder: GitWorkingFolder
  var source: GitSourcePreparation
  let discovery: String
  let policy: GitPreparationPolicy
  var phase: Phase
}

enum GitFrontierPublication {
  /// refresh(repo, active frontier, its ref count) re-observes an active frontier the staged refs equal.
  case staging(Int), begin(Int), row(Int, String), chunk(Int, String, Int), certify(Int, String, Int), refresh(Int, String, Int), nativeFailure(Int)
  var repo: Int {
    switch self {
    case .staging(let repo), .begin(let repo), .row(let repo, _), .chunk(let repo, _, _), .certify(let repo, _, _), .refresh(let repo, _, _),
      .nativeFailure(let repo): return repo
    }
  }
}

enum GitDiagnosticPublication {
  case folder(Int), repository(Int)
}

enum GitPublicationOperation {
  case discovery(GitDiscoveryPublication)
  case diagnostic(GitDiagnosticPublication)
  case commitParent(GitCommitPublication)
  case commitUnit(Int)
  case commitCompletion(Int)

  case frontier(GitFrontierPublication)
}

/// Hash-only ownership answers, in memory only. A candidate found absent stays absent while
/// the receipt registry and the baseline are unchanged. A selector found holding no owned row
/// also needs every folder row unchanged, which the source revision counts.
struct GitOwnershipMemo {
  var registry: String?
  var absent = Set<String>()
  var source: Int?
  var clean = Set<String>()
}

enum GitPublicationRefusal: Equatable {
  case interrupted, privacy, expired, known
}

enum GitPublicationResult<Value> {
  case admitted(Value)
  case refused(GitPublicationRefusal)
  var value: Value? { if case .admitted(let value) = self { return value }; return nil }
}

extension ActivityStorage {
  /// A rejected operation cannot execute its write closure. Callers supply typed
  /// facts, never a Boolean assembled from a selectable subset of policy checks.
  func publishGit<T>(_ operation: GitPublicationOperation, now: Int, _ write: () throws -> T) throws -> GitPublicationResult<T> {
    // Frontier loops share one dispatch work item. Drain receipt/JSON Foundation
    // temporaries after each unit releases the writer, independent of payload size.
    try autoreleasepool {
      try gitLocked {
        gitPublishCalls += 1
        do {
          let result: GitPublicationResult<T> = try gitTransaction(certifying: true) {
            try reconcileGitOwnership(operation)
            if let refusal = try gitPublicationRefusal(operation, now: now) {
              if case .commitCompletion(let id) = operation {
                try connection.run("UPDATE git_commits SET complete=-1 WHERE id=? AND complete=0", [.integer(id)])
                gitCommitReads[id]?.state = refusal == .privacy || refusal == .expired ? .refused : .uncertifiedDebt
              }
              return .refused(refusal)
            }
            return .admitted(try write())
          }
          switch result {
          case .admitted: gitDidPublish(operation)
          case .refused(.interrupted): gitDidInterrupt(operation)
          case .refused(.privacy), .refused(.expired), .refused(.known): break
          }
          return result
        } catch {
          gitDidInterrupt(operation)
          throw error
        }
      }
    }
  }

  /// Revalidate the exact hash-only path/session/home receipt set after writer
  /// admission. Removing one owned link preserves independent repository sources.
  private func reconcileGitOwnership(_ operation: GitPublicationOperation) throws {
    let selector: String
    let value: SQLValue
    let scope: String
    switch operation {
    case .discovery(let context):
      switch context.phase {
      case .touch(let id), .branch(let id), .complete(let id): selector = "id=?"; value = .integer(id); scope = "id:\(id)"
      case .register, .touchValidation:
        let key = Self.gitFolderKey(context.folder)
        selector = "identity=?"; value = .key(key); scope = "identity:" + key
      }
    case .diagnostic(.folder(let id)): selector = "id=?"; value = .integer(id); scope = "id:\(id)"
    case .diagnostic(.repository(let repo)):
      selector = "repo_id=?"; value = .integer(repo); scope = "repo:\(repo)"
    case .commitParent(let receipt): selector = "repo_id=?"; value = .integer(receipt.repo); scope = "repo:\(receipt.repo)"
    case .commitUnit(let id), .commitCompletion(let id):
      guard let receipt = gitCommitReads[id] else { return }
      selector = "repo_id=?"; value = .integer(receipt.repo); scope = "repo:\(receipt.repo)"
    case .frontier(let frontier): selector = "repo_id=?"; value = .integer(frontier.repo); scope = "repo:\(frontier.repo)"
    }
    // One baseline read per publish instead of one query per candidate.
    var baseline: Set<String>?
    let registry = ownLogSources(retainedReceipt: { key in
      if baseline == nil {
        var keys = Set<String>()
        try self.connection.rows("SELECT receipt FROM agent_log_own_baseline") { keys.insert(SQLiteConnection.text($0, 0)) }
        baseline = keys
      }
      return baseline!.contains(key)
    })
    // Read before any candidate: a receipt added meanwhile changes the state the next publish
    // reads. Without a state every candidate is looked up, as when nothing is remembered.
    let state = try? gitOwnershipState(registry)
    if state == nil || gitOwnershipMemo.registry != state { gitOwnershipMemo = GitOwnershipMemo(registry: state) }
    let source = state == nil ? nil : try gitSourceRevision()
    if source == nil || gitOwnershipMemo.source != source { gitOwnershipMemo.source = source; gitOwnershipMemo.clean = [] }
    if source != nil, gitOwnershipMemo.clean.contains(scope) { return }
    var owned: [Int] = []
    try connection.namedRows("SELECT id,ownership_authority FROM git_working_folders WHERE \(selector)", [value]) {
      try checkGitCancellation()
      let encoded = try $0.text("ownership_authority")
      // Legacy links cannot authorize publication until raw discovery supplies authority.
      guard !encoded.isEmpty else { return }
      let authority = try JSONDecoder().decode([String].self, from: Data(encoded.utf8))
      guard !authority.isEmpty else { throw AgentLogOwnSources.AuthorityError.invalidReceipt }
      for candidate in authority where !gitOwnershipMemo.absent.contains(candidate) {
        gitOwnershipLookups += 1
        if try registry.containsAuthority([candidate]) { owned.append(try $0.int("id")); break }
        if state != nil { gitOwnershipMemo.absent.insert(candidate) }
      }
    }
    for id in owned {
      try connection.run("DELETE FROM git_working_folders WHERE id=?", [.integer(id)])
    }
    if !owned.isEmpty { try cleanGitOrphans() }
    // Read inside this transaction before its write: a write to any folder row moves the
    // revision, and a rollback restores the rows this answer was found for.
    else if source != nil { gitOwnershipMemo.clean.insert(scope) }
  }

  /// The receipt registry folder's revision and the baseline. Both only grow; the folder
  /// changes status whenever a receipt is added or removed.
  private func gitOwnershipState(_ registry: AgentLogOwnSources) throws -> String {
    var baseline = ""
    try connection.namedRows("SELECT count(*) AS n,COALESCE(min(receipt),'') AS low,COALESCE(max(receipt),'') AS high FROM agent_log_own_baseline") {
      baseline = [String(try $0.int("n")), try $0.text("low"), try $0.text("high")].joined(separator: ":")
    }
    return try registry.revision() + "|" + baseline
  }

  /// A failed child stream may already own durable chunks. Latch interruption
  /// even if the caller catches the error and later asks to complete the parent.
  func withGitCommitWork<T>(_ id: Int, _ body: () throws -> T) throws -> T {
    do { return try body() }
    catch {
      try? gitLocked { gitDidInterrupt(.commitUnit(id)) }
      throw error
    }
  }

  /// An owned producer cannot be replaced by a fresh or missing call scope.
  /// Matching identity also makes COMMIT certify the producer's actual token.
  private func gitProducerAllowed(_ owner: GitTaskCancellation?) -> Bool {
    guard let owner else { return true }
    let current = Thread.current.threadDictionary[gitCancellationKey] as? GitTaskCancellation
    return current === owner && !owner.isCancelled
  }

  private func gitDidPublish(_ operation: GitPublicationOperation) {
    switch operation {
    case .discovery(let context):
      switch context.phase {
      case .register: gitFolderPreparations[ActivityStorage.gitFolderKey(context.folder)]?.state = .admitted
      case .complete: gitFolderPreparations[ActivityStorage.gitFolderKey(context.folder)]?.state = .complete
      case .branch, .touch, .touchValidation: break
      }
    case .commitCompletion(let id): gitCommitReads[id]?.state = .complete
    case .frontier(.certify(let repo, _, _)), .frontier(.refresh(let repo, _, _)): gitReads[repo]?.state = .complete
    case .diagnostic, .commitParent, .commitUnit, .frontier: break
    }
  }

  private func gitDidInterrupt(_ operation: GitPublicationOperation) {
    switch operation {
    case .discovery(let context): gitFolderPreparations[ActivityStorage.gitFolderKey(context.folder)]?.state = .interrupted
    case .commitParent(let read): interruptGitRead(read.repo)
    case .commitUnit(let id), .commitCompletion(let id):
      if let read = gitCommitReads[id] { interruptGitRead(read.repo) }
      gitCommitReads[id]?.state = .interrupted
    case .frontier(let operation): interruptGitRead(operation.repo)
    case .diagnostic: break
    }
  }

  /// Read-only discovery preflight shares the gate predicate. It cannot request
  /// commit refusal writes or certification outside the publishing transaction.
  func gitDiscoveryPermitted(_ context: GitDiscoveryPublication, now: Int) throws -> Bool {
    try gitPublicationRefusal(.discovery(context), now: now) == nil
  }

  private func gitPublicationRefusal(_ operation: GitPublicationOperation, now: Int) throws -> GitPublicationRefusal? {
    try checkGitCancellation()
    switch operation {
    case .diagnostic(let diagnostic):
      guard try gitRecordingAllowed(at: now), try gitAllowed(now), now >= (try gitRetentionCutoff(now: now)) else { return .interrupted }
      switch diagnostic {
      case .repository(let repo): return try gitRepositoryPermitted(repo) ? nil : .interrupted
      case .folder(let id):
        var eligible = false
        try connection.namedRows("SELECT f.ts,f.last_seen,f.folder,f.tool FROM git_working_folders f WHERE f.id=? AND \(gitPermittedSourcePredicate)", [.integer(id)]) {
          let time = try $0.int("ts")
          eligible = try AgentLogTool(rawValue: $0.text("tool")) != nil && !AgentWindowIdentity.containsWorkingFolder($0.text("folder"))
            && gitAllowed(time) && $0.int("last_seen") >= gitRetentionCutoff(now: now)
        }
        return eligible ? nil : .interrupted
      }
    case .frontier(let frontier): return try gitFrontierRefusal(frontier, now: now)
    case .commitParent(let receipt):
      guard gitProducerAllowed(receipt.cancellation), receipt.generation == receipt.policy.generation,
        receipt.generation == (try gitPrivacyGeneration()),
        try gitRecordingAllowed(at: now), try gitRepositoryPermitted(receipt.repo) else {
        interruptGitRead(receipt.repo); return .interrupted
      }
      if try gitCommitKnown(repo: receipt.repo, hash: receipt.hash) { return .known }
      // Identity refusals precede receipt revision checks: forget during an
      // expensive preparation must still block replay of the same hash.
      if let refusal = try gitNativeTimeRefusal(receipt) {
        if refusal == .privacy { try connection.run("INSERT OR IGNORE INTO git_tombstones VALUES(?)", [.key(receipt.hash)]) }
        else { interruptGitRead(receipt.repo) }
        return refusal
      }
      if let refusal = try gitCommitPolicyRefusal(receipt, now: now) {
        if refusal == .interrupted { interruptGitRead(receipt.repo) }
        return refusal
      }
      return nil
    case .commitUnit(let id), .commitCompletion(let id):
      guard let receipt = gitCommitReads[id], gitProducerAllowed(receipt.cancellation) else { return .interrupted }
      var times: (Int, Int)?
      try connection.namedRows("SELECT author_ts,ts FROM git_commits WHERE id=? AND complete=0", [.integer(id)]) {
        times = (try $0.int("author_ts"), try $0.int("ts"))
      }
      if try gitCommitWasForgotten(id) { return .privacy }
      guard let times, times.0 == receipt.authorTime, times.1 == receipt.commitTime else {
        gitCommitReads[id]?.state = .interrupted; return .interrupted
      }
      if let refusal = try gitNativeTimeRefusal(receipt) {
        if case .commitCompletion = operation, refusal == .privacy {
          try connection.run("INSERT OR IGNORE INTO git_tombstones VALUES(?)", [.key(receipt.hash)])
        }
        gitCommitReads[id]?.state = refusal == .privacy ? .refused : .interrupted
        return refusal
      }
      // Expiry is terminal only for this traversal, never a permanent marker.
      let cutoff = try gitRetentionCutoff(now: now)
      if receipt.authorTime < cutoff || receipt.commitTime < cutoff {
        gitCommitReads[id]?.state = .interrupted
        return .expired
      }
      guard receipt.state == .admitted else { return .interrupted }
      if let refusal = try gitCommitPolicyRefusal(receipt, now: now) {
        gitCommitReads[id]?.state = .interrupted
        return refusal
      }
      return nil
    case .discovery(let context):
      let folder = context.folder
      guard try gitPolicyAllowed(generation: context.policy.generation, policy: context.policy, now: now),
        try gitAllowed(folder.time), folder.time >= (try gitRetentionCutoff(now: now)),
        !AgentWindowIdentity.containsWorkingFolder(folder.folder),
        try gitSourceAllowed(folder, prepared: context.source, discovery: context.discovery) else { return .interrupted }
      switch context.phase {
      case .touchValidation: break
      case .register(let identity):
        guard try connection.integer("SELECT count(*) FROM git_working_folders WHERE identity=? AND ((repo_id IS NOT NULL AND complete=1) OR attempt_ts=?)",
          [.key(identity), .integer(now)]) == 0 else { return .known }
      case .branch(let id), .complete(let id):
        guard let producer = gitFolderPreparations[ActivityStorage.gitFolderKey(folder)],
          producer.state == .admitted, gitProducerAllowed(producer.cancellation) else { return .interrupted }
        guard try connection.integer("SELECT count(*) FROM git_working_folders WHERE id=? AND complete=0", [.integer(id)]) == 1 else { return .interrupted }
      case .touch(let id):
        guard try connection.integer("SELECT count(*) FROM git_working_folders WHERE id=? AND complete=1", [.integer(id)]) == 1 else { return .interrupted }
      }
      return nil
    }
  }

  private func gitFrontierRefusal(_ operation: GitFrontierPublication, now: Int) throws -> GitPublicationRefusal? {
    let repo = operation.repo
    guard let read = gitReads[repo], gitProducerAllowed(read.cancellation), try gitPolicyAllowed(generation: read.policy.generation, policy: read.policy, now: now),
      read.preparedAt >= (try gitRetentionCutoff(now: now)), try gitRepositoryPermitted(repo) else { return .interrupted }
    // Actual native read failure can be counted after an interrupted commit has
    // invalidated frontier certification, under the original immutable receipt.
    if case .nativeFailure = operation { return nil }
    if case .staging = operation { return read.state == .admitted ? nil : .interrupted }
    guard read.state == .admitted,
      try connection.integer("SELECT EXISTS(SELECT 1 FROM git_commits WHERE repo_id=? AND complete!=1)", [.integer(repo)]) == 0 else { return .interrupted }
    let token: String
    switch operation {
    case .staging, .begin: return nil
    case .refresh(_, let active, let count):
      // The active frontier is still the one the staged refs were compared with, whole.
      guard try connection.integer("SELECT count(*) FROM git_repositories WHERE id=? AND frontier=? AND pending_frontier=''", [.integer(repo), .key(active)]) == 1,
        try connection.integer("SELECT count(*) FROM git_refs WHERE repo_id=? AND frontier=?", [.integer(repo), .key(active)]) == count else { return .interrupted }
      return nil
    case .row(_, let value), .chunk(_, let value, _), .certify(_, let value, _): token = value
    case .nativeFailure: return nil
    }
    guard try connection.integer("SELECT count(*) FROM git_repositories WHERE id=? AND pending_frontier=?", [.integer(repo), .key(token)]) == 1 else { return .interrupted }
    switch operation {
    case .chunk(_, _, let id):
      guard try connection.integer("SELECT count(*) FROM git_refs WHERE id=? AND repo_id=? AND frontier=?", [.integer(id), .integer(repo), .key(token)]) == 1 else { return .interrupted }
    case .certify(_, _, let count):
      guard try connection.integer("SELECT pending_ref_count FROM git_repositories WHERE id=?", [.integer(repo)]) == count else { return .interrupted }
    case .staging, .begin, .row, .refresh, .nativeFailure: break
    }
    return nil
  }

  func interruptGitRead(_ repo: Int) { gitReads[repo]?.state = .interrupted }

  var gitPermittedSourcePredicate: String {
    """
    f.complete=1 AND f.source!='' AND f.ownership_authority!='' AND f.tool IN ('claude','codex')
      AND NOT EXISTS(SELECT 1 FROM agent_log_revoked_sessions r WHERE r.tool=f.tool AND r.session_id=f.session)
      AND NOT EXISTS(SELECT 1 FROM agent_log_tool_own_sources o
        WHERE o.tool=f.tool AND o.device=f.device AND o.inode=f.inode AND o.path=f.source)
      AND NOT EXISTS(SELECT 1 FROM git_discovery_tombstones t WHERE t.hash=f.discovery)
      AND NOT EXISTS(SELECT 1 FROM forgotten_ranges r WHERE r.start_ts<=f.ts AND r.end_ts>f.ts)
      AND COALESCE((SELECT h.enabled!=0 AND (h.paused_until IS NULL OR h.paused_until<=f.ts)
        FROM log_recording_history h WHERE h.since<=f.ts ORDER BY h.since DESC,h.id DESC LIMIT 1),0)=1
      AND NOT EXISTS(SELECT 1 FROM log_positions p INDEXED BY log_positions_git_recovery WHERE p.path=f.source AND p.device=f.device AND p.inode=f.inode
        AND json_valid(p.state) AND json_extract(p.state,'$.metadataRecoveryOffset') IS NOT NULL)
    """
  }

  func gitRepositoryPermitted(_ repo: Int) throws -> Bool {
    try connection.integer("SELECT count(*) FROM git_repositories WHERE id=? AND \(collectibleGitRepository)", [.integer(repo)]) == 1
  }

  private func gitNativeTimeRefusal(_ receipt: GitCommitPublication) throws -> GitPublicationRefusal? {
    for time in [receipt.authorTime, receipt.commitTime] {
      guard time < Int.max else { return .interrupted }
      if try forgotten(TimeRange(time, time + 1)) { return .privacy }
      var permission: Bool?
      try connection.namedRows("SELECT enabled,CAST(paused_until AS TEXT) AS pause FROM log_recording_history WHERE since<=? ORDER BY since DESC,id DESC LIMIT 1", [.integer(time)]) {
        permission = try $0.int("enabled") != 0 && ($0.optionalText("pause").flatMap(Int.init) ?? Int.min) <= time
      }
      guard let permission else { return .interrupted }
      if !permission { return .privacy }
    }
    return nil
  }

  private func gitCommitPolicyRefusal(_ receipt: GitCommitPublication, now: Int) throws -> GitPublicationRefusal? {
    guard try gitPolicyAllowed(generation: receipt.generation, policy: receipt.policy, now: now),
      try gitRepositoryPermitted(receipt.repo) else { return .interrupted }
    let cutoff = try gitRetentionCutoff(now: now)
    return receipt.authorTime < cutoff || receipt.commitTime < cutoff ? .expired : nil
  }
}
