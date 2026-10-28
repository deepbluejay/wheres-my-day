import Core
import CryptoKit
import Foundation
import SQLite3

struct GitDeletionFingerprint {
  var digest: Data
  var counts: [String: Int]
  var revision: Int?
}

struct GitSourcePreparation {
  var revision: Int?
  var recovery = false
  var own = false
  var candidates: [AgentLogSessionSubject] = []
  var provenance: [(AgentLogTool, AgentLogSessionSubject)] = []
  var authority: [String] = []
}

private enum GitChunkInterruption: Error { case forgotten }

extension ActivityStorage {
  private func gitStageLocked<T>(_ body: () throws -> T) throws -> T {
    let cancellation = Thread.current.threadDictionary[gitCancellationKey] as? GitTaskCancellation
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !gitStageLock.lock(before: Date(timeIntervalSinceNow: 0.005)) {
      try cancellation?.checkCleanup()
      if cancellation != nil && ProcessInfo.processInfo.systemUptime >= deadline { throw StorageError.busy("Git stage admission timed out") }
    }
    defer { gitStageLock.unlock() }
    if let stage = gitStageConnection { return try stage.withGitAdmission(cancellation, body) }
    return try body()
  }
  /// Scope is worker-local: discovery and history can share storage without replacing
  /// each other's receipt, and privacy/retention work remains independent of task stop.
  public func withGitCancellation<T>(_ cancellation: GitTaskCancellation, _ body: () throws -> T) rethrows -> T {
    let previous = Thread.current.threadDictionary[gitCancellationKey]
    Thread.current.threadDictionary[gitCancellationKey] = cancellation
    defer {
      if let previous { Thread.current.threadDictionary[gitCancellationKey] = previous }
      else { Thread.current.threadDictionary.removeObject(forKey: gitCancellationKey) }
    }
    return try body()
  }
  func checkGitCancellation() throws {
    try (Thread.current.threadDictionary[gitCancellationKey] as? GitTaskCancellation)?.check()
  }
  func gitLocked<T>(_ body: () throws -> T) throws -> T {
    let cancellation = Thread.current.threadDictionary[gitCancellationKey] as? GitTaskCancellation
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !lock.lock(before: Date(timeIntervalSinceNow: 0.005)) {
      try cancellation?.checkCleanup()
      if cancellation != nil && ProcessInfo.processInfo.systemUptime >= deadline { throw StorageError.busy("Git writer admission timed out") }
    }
    defer { lock.unlock() }
    return try connection.withGitAdmission(cancellation, body)
  }
  /// Writer admission and all policy queries precede the short receipt/COMMIT section.
  /// Any stop during admission or preparation rolls the entire transaction back.
  func gitTransaction<T>(certifying: Bool = false, cleanup: Bool = false, _ body: () throws -> T) throws -> T {
    try connection.run("BEGIN IMMEDIATE")
    do {
      if !cleanup { try checkGitCancellation() }
      let result = try body()
      if certifying, let cancellation = Thread.current.threadDictionary[gitCancellationKey] as? GitTaskCancellation {
        try cancellation.certify { try connection.run("COMMIT") }
      } else { try connection.run("COMMIT") }
      return result
    } catch {
      try? connection.run("ROLLBACK")
      throw error
    }
  }
  private func gitUnit(_ phase: String) throws {
    try afterGitUnit?(phase)
    try checkGitCancellation()
  }
  private func checkGitCleanup() throws {
    try (Thread.current.threadDictionary[gitCancellationKey] as? GitTaskCancellation)?.checkCleanup()
  }
  private func gitCleanupUnit(_ phase: String) throws {
    try afterGitUnit?(phase)
    try checkGitCleanup()
  }

  /// Abandonment is durable, separate from a privacy refusal. Run independently of
  /// Recording so stop cannot strand cancelled bytes indefinitely.
  public func cleanGitCancelledWork() throws {
    for (repo, cancellation) in try gitLocked({ gitReads.compactMap { repo, read in read.cancellation.map { (repo, $0) } } }) {
      try checkGitCleanup()
      if cancellation.isCancelled { try finishGitRead(repo: repo, now: 0, outcome: .interrupted) }
    }
    var orphanCursor = 0
    while let id = try gitLocked({ () throws -> Int? in
      var next: Int?
      try connection.namedRows("SELECT id FROM git_commits WHERE complete=0 AND id>? ORDER BY id LIMIT 1", [.integer(orphanCursor)]) { next = try $0.int("id") }
      return next
    }) {
      try checkGitCleanup(); orphanCursor = id
      if try gitLocked({ gitCommitReads[id] == nil || gitCommitReads[id]?.cancellation?.isCancelled == true }) { try abandonGitCommit(id) }
    }
    orphanCursor = 0
    while let folder = try gitLocked({ () throws -> (Int, String)? in
      var next: (Int, String)?
      try connection.namedRows("SELECT id,identity FROM git_working_folders WHERE complete=0 AND id>? ORDER BY id LIMIT 1", [.integer(orphanCursor)]) { next = (try $0.int("id"), try $0.text("identity")) }
      return next
    }) {
      try checkGitCleanup(); orphanCursor = folder.0
      if try gitLocked({ gitFolderPreparations[folder.1] == nil || gitFolderPreparations[folder.1]?.cancellation?.isCancelled == true }) { try discardGitFolderPreparation(identity: folder.1) }
    }
    while let id = try gitLocked({ () throws -> Int? in
      var id: Int?
      try connection.namedRows("SELECT id FROM git_commits WHERE complete=-1 ORDER BY id LIMIT 1") { id = try $0.int("id") }
      return id
    }) {
      try checkGitCleanup()
      try discardGitCommitContent(id)
    }
    while let identity = try gitLocked({ () throws -> String? in
      var identity: String?
      try connection.namedRows("SELECT identity FROM git_working_folders WHERE complete=-1 ORDER BY id LIMIT 1") { identity = try $0.text("identity") }
      return identity
    }) {
      try checkGitCleanup()
      try discardGitFolderPreparation(identity: identity)
    }
    var cursor = 0
    while let repo = try gitLocked({ () throws -> Int? in
      var id: Int?
      try connection.namedRows("SELECT id FROM git_repositories WHERE id>? ORDER BY id LIMIT 1", [.integer(cursor)]) { id = try $0.int("id") }
      return id
    }) {
      try checkGitCleanup(); cursor = repo
      try gitLocked {
        if gitReads[repo]?.state != .admitted {
          try connection.run("UPDATE git_repositories SET pending_frontier='',pending_ref_count=0 WHERE id=? AND pending_frontier!=''", [.integer(repo)])
        }
      }
      try cleanGitFrontiers(repo: repo)
    }
  }

  private func discardGitCommitContent(_ id: Int) throws {
    while true {
      try checkGitCleanup()
      let changed = try gitLocked { () throws -> Bool in
        try connection.run("DELETE FROM git_commit_text WHERE id IN (SELECT id FROM git_commit_text WHERE commit_id=? AND EXISTS(SELECT 1 FROM git_commits WHERE id=? AND complete=-1) LIMIT 16)", [.integer(id), .integer(id)])
        return sqlite3_changes(connection.handle) > 0
      }
      guard changed else { break }
      try gitCleanupUnit("commit-cleanup"); Thread.sleep(forTimeInterval: 0.001)
    }
    for (kind, table) in [(1, "git_files"), (2, "git_commit_refs")] {
      while true {
        try checkGitCleanup()
        let child: Int? = try gitLocked {
          var child: Int?
          try connection.namedRows("SELECT id FROM \(table) WHERE commit_id=? AND EXISTS(SELECT 1 FROM git_commits WHERE id=? AND complete=-1) ORDER BY id LIMIT 1", [.integer(id), .integer(id)]) { child = try $0.int("id") }
          return child
        }
        guard let child else { break }
        while true {
          try checkGitCleanup()
          let changed = try gitLocked { () throws -> Bool in
            try connection.run("DELETE FROM git_value_text WHERE id IN (SELECT id FROM git_value_text WHERE kind=? AND owner_id=? AND EXISTS(SELECT 1 FROM git_commits WHERE id=? AND complete=-1) LIMIT 16)", [.integer(kind), .integer(child), .integer(id)])
            return sqlite3_changes(connection.handle) > 0
          }
          guard changed else { break }
          try gitCleanupUnit("commit-cleanup"); Thread.sleep(forTimeInterval: 0.001)
        }
        try gitLocked { try connection.run("DELETE FROM \(table) WHERE id=? AND commit_id=? AND EXISTS(SELECT 1 FROM git_commits WHERE id=? AND complete=-1)", [.integer(child), .integer(id), .integer(id)]) }
        try gitCleanupUnit("commit-child-cleanup"); Thread.sleep(forTimeInterval: 0.001)
      }
    }
    try gitLocked { try connection.run("DELETE FROM git_commits WHERE id=? AND complete=-1", [.integer(id)]) }
  }
}

extension SQLiteConnection {
  func createGitTextSchema() throws {
    try run("CREATE TABLE IF NOT EXISTS git_retention_progress(id INTEGER PRIMARY KEY CHECK(id=1),maintained_at INTEGER NOT NULL)")
    // A mark says every retained occurrence up to event_id was offered to discovery.
    // Event ids are reusable rowids, so deleting the largest id lowers every larger
    // mark with it; a reused id can never fall behind a mark. Deleting older rows,
    // as retention does, leaves the maximum alone and skips the body.
    try run("CREATE TABLE IF NOT EXISTS git_backfill_progress(source TEXT PRIMARY KEY,event_id INTEGER NOT NULL)")
    try run("CREATE INDEX IF NOT EXISTS git_backfill_progress_event ON git_backfill_progress(event_id)")
    try run("""
      CREATE TRIGGER IF NOT EXISTS git_backfill_progress_clamp AFTER DELETE ON agent_log_events
      WHEN OLD.id>(SELECT COALESCE(max(id),0) FROM agent_log_events) BEGIN
        UPDATE git_backfill_progress SET event_id=(SELECT COALESCE(max(id),0) FROM agent_log_events)
          WHERE event_id>(SELECT COALESCE(max(id),0) FROM agent_log_events);
      END
      """)
    try run("""
      CREATE TABLE IF NOT EXISTS git_commit_text(
        id INTEGER PRIMARY KEY,commit_id INTEGER NOT NULL,field INTEGER NOT NULL,ordinal INTEGER NOT NULL,
        payload BLOB NOT NULL,UNIQUE(commit_id,field,ordinal))
      """)
    try run("""
      CREATE TRIGGER IF NOT EXISTS git_text_cleanup AFTER DELETE ON git_commits BEGIN
        DELETE FROM git_commit_text WHERE commit_id=OLD.id;
      END
      """)
    try run("""
      CREATE TABLE IF NOT EXISTS git_value_text(
        id INTEGER PRIMARY KEY,kind INTEGER NOT NULL,owner_id INTEGER NOT NULL,field INTEGER NOT NULL,
        ordinal INTEGER NOT NULL,payload BLOB NOT NULL,UNIQUE(kind,owner_id,field,ordinal))
      """)
    for (kind, table) in [(1, "git_files"), (2, "git_commit_refs"), (3, "git_refs"), (4, "git_working_folders")] {
      try run("""
        CREATE TRIGGER IF NOT EXISTS \(table)_text_cleanup AFTER DELETE ON \(table) BEGIN
          DELETE FROM git_value_text WHERE kind=\(kind) AND owner_id=OLD.id;
        END
        """)
    }
    if try integer("SELECT count(*) FROM pragma_table_info('git_working_folders') WHERE name='complete'") == 0 {
      try run("ALTER TABLE git_working_folders ADD COLUMN complete INTEGER NOT NULL DEFAULT 1")
    }
    if try integer("SELECT count(*) FROM pragma_table_info('git_working_folders') WHERE name='ownership_authority'") == 0 {
      try run("ALTER TABLE git_working_folders ADD COLUMN ownership_authority TEXT NOT NULL DEFAULT ''")
    }
    for table in ["git_repositories", "git_refs"] {
      if try integer("SELECT count(*) FROM pragma_table_info('\(table)') WHERE name='frontier'") == 0 {
        try run("ALTER TABLE \(table) ADD COLUMN frontier TEXT NOT NULL DEFAULT ''")
      }
    }
    if try integer("SELECT count(*) FROM pragma_table_info('git_repositories') WHERE name='pending_frontier'") == 0 {
      try run("ALTER TABLE git_repositories ADD COLUMN pending_frontier TEXT NOT NULL DEFAULT ''")
    }
    if try integer("SELECT count(*) FROM pragma_table_info('git_repositories') WHERE name='pending_ref_count'") == 0 {
      try run("ALTER TABLE git_repositories ADD COLUMN pending_ref_count INTEGER NOT NULL DEFAULT 0")
    }
    try run("CREATE TRIGGER IF NOT EXISTS git_ref_pending_insert AFTER INSERT ON git_refs BEGIN UPDATE git_repositories SET pending_ref_count=pending_ref_count+1 WHERE id=NEW.repo_id AND pending_frontier=NEW.frontier; END")
    try run("CREATE TRIGGER IF NOT EXISTS git_ref_pending_delete AFTER DELETE ON git_refs BEGIN UPDATE git_repositories SET pending_ref_count=pending_ref_count-1 WHERE id=OLD.repo_id AND pending_frontier=OLD.frontier; END")
    try run("CREATE TRIGGER IF NOT EXISTS git_ref_pending_update AFTER UPDATE OF repo_id,frontier ON git_refs BEGIN UPDATE git_repositories SET pending_ref_count=pending_ref_count-1 WHERE id=OLD.repo_id AND pending_frontier=OLD.frontier; UPDATE git_repositories SET pending_ref_count=pending_ref_count+1 WHERE id=NEW.repo_id AND pending_frontier=NEW.frontier; END")
    try run("CREATE INDEX IF NOT EXISTS git_ref_frontier ON git_refs(repo_id,frontier,id)")
    try run("CREATE INDEX IF NOT EXISTS git_ref_repo_id ON git_refs(repo_id,id)")
    try run("CREATE INDEX IF NOT EXISTS git_commit_completion ON git_commits(repo_id,complete)")
    try run("CREATE INDEX IF NOT EXISTS git_abandoned_commits ON git_commits(id) WHERE complete=-1")
    try run("CREATE INDEX IF NOT EXISTS git_abandoned_folders ON git_working_folders(id) WHERE complete=-1")
    try run("CREATE INDEX IF NOT EXISTS git_incomplete_commits ON git_commits(id) WHERE complete=0")
    try run("CREATE INDEX IF NOT EXISTS git_incomplete_folders ON git_working_folders(id) WHERE complete=0")
    try run("CREATE INDEX IF NOT EXISTS git_file_commit ON git_files(commit_id,id)")
    try run("CREATE INDEX IF NOT EXISTS git_commit_ref_owner ON git_commit_refs(commit_id,id)")
    try run("CREATE INDEX IF NOT EXISTS log_positions_git_recovery ON log_positions(path,device,inode) WHERE json_valid(state) AND json_extract(state,'$.metadataRecoveryOffset') IS NOT NULL")
    try run("CREATE TABLE IF NOT EXISTS git_privacy_revision(id INTEGER PRIMARY KEY CHECK(id=1),value INTEGER NOT NULL)")
    try run("INSERT OR IGNORE INTO git_privacy_revision VALUES(1,0)")
    for table in ["git_repositories", "git_working_folders", "git_refs", "git_commits", "git_commit_refs", "git_files", "git_commit_text", "git_value_text", "log_positions", "agent_log_events", "agent_log_event_sessions"] {
      for action in ["INSERT", "UPDATE", "DELETE"] {
        try run("CREATE TRIGGER IF NOT EXISTS git_revision_\(table)_\(action.lowercased()) AFTER \(action) ON \(table) BEGIN UPDATE git_privacy_revision SET value=value+1 WHERE id=1; END")
      }
    }
    try run("CREATE TABLE IF NOT EXISTS git_discovery_tombstones(hash TEXT PRIMARY KEY)")
    try run("CREATE TABLE IF NOT EXISTS git_source_revision(id INTEGER PRIMARY KEY CHECK(id=1),value INTEGER NOT NULL)")
    try run("INSERT OR IGNORE INTO git_source_revision VALUES(1,0)")
    for table in ["log_positions", "agent_log_events", "agent_log_event_sessions", "agent_log_revoked_sessions", "agent_log_tool_own_sources", "git_discovery_tombstones", "git_working_folders"] {
      for action in ["INSERT", "UPDATE", "DELETE"] {
        try run("CREATE TRIGGER IF NOT EXISTS git_source_revision_\(table)_\(action.lowercased()) AFTER \(action) ON \(table) BEGIN UPDATE git_source_revision SET value=value+1 WHERE id=1; END")
      }
    }
  }
  func createGitSchema() throws {
    for sql in [
      """
      CREATE TABLE IF NOT EXISTS git_repositories(
        id INTEGER PRIMARY KEY AUTOINCREMENT, identity TEXT NOT NULL UNIQUE, common_dir TEXT NOT NULL,
        ts INTEGER NOT NULL, last_read INTEGER, failures INTEGER NOT NULL DEFAULT 0)
      """,
      """
      CREATE TABLE IF NOT EXISTS git_working_folders(
        id INTEGER PRIMARY KEY AUTOINCREMENT, identity TEXT NOT NULL UNIQUE, source TEXT NOT NULL,
        device INTEGER NOT NULL,inode INTEGER NOT NULL,session TEXT NOT NULL,folder TEXT NOT NULL,
        repo_id INTEGER,top_level TEXT NOT NULL,branch TEXT NOT NULL,head TEXT NOT NULL,
        ts INTEGER NOT NULL,last_seen INTEGER NOT NULL,attempt_ts INTEGER NOT NULL,status TEXT NOT NULL,failures INTEGER NOT NULL DEFAULT 0)
      """,
      "CREATE INDEX IF NOT EXISTS git_folder_repo ON git_working_folders(repo_id)",
      "CREATE INDEX IF NOT EXISTS git_folder_source ON git_working_folders(device,inode,source)",
      """
      CREATE TABLE IF NOT EXISTS git_refs(
        id INTEGER PRIMARY KEY,repo_id INTEGER NOT NULL,identity TEXT NOT NULL,name TEXT NOT NULL,
        tip TEXT NOT NULL,ts INTEGER NOT NULL,UNIQUE(repo_id,identity))
      """,
      """
      CREATE TABLE IF NOT EXISTS git_commits(
        id INTEGER PRIMARY KEY AUTOINCREMENT,repo_id INTEGER NOT NULL,hash TEXT NOT NULL,author_ts INTEGER NOT NULL,
        ts INTEGER NOT NULL,author TEXT NOT NULL,email TEXT NOT NULL,message TEXT NOT NULL,
        complete INTEGER NOT NULL DEFAULT 0,UNIQUE(repo_id,hash))
      """,
      "CREATE INDEX IF NOT EXISTS git_commit_time ON git_commits(ts,author_ts)",
      """
      CREATE TABLE IF NOT EXISTS git_commit_refs(
        id INTEGER PRIMARY KEY,commit_id INTEGER NOT NULL,identity TEXT NOT NULL,name TEXT NOT NULL,UNIQUE(commit_id,identity))
      """,
      """
      CREATE TABLE IF NOT EXISTS git_files(
        id INTEGER PRIMARY KEY,commit_id INTEGER NOT NULL,old_path TEXT NOT NULL,path TEXT NOT NULL,
        added INTEGER,deleted INTEGER)
      """,
      "CREATE INDEX IF NOT EXISTS git_file_commit ON git_files(commit_id)",
      "CREATE TABLE IF NOT EXISTS git_tombstones(hash TEXT PRIMARY KEY)",
      """
      CREATE TRIGGER IF NOT EXISTS git_commit_cleanup AFTER DELETE ON git_commits BEGIN
        DELETE FROM git_files WHERE commit_id=OLD.id;
        DELETE FROM git_commit_refs WHERE commit_id=OLD.id;
      END
      """,
      """
      CREATE TRIGGER IF NOT EXISTS git_repo_cleanup AFTER DELETE ON git_repositories BEGIN
        DELETE FROM git_commits WHERE repo_id=OLD.id;
        DELETE FROM git_refs WHERE repo_id=OLD.id;
        DELETE FROM git_working_folders WHERE repo_id=OLD.id;
      END
      """,
    ] { try run(sql) }
    try createGitTextSchema()
    var columns = Set<String>()
    try rows("PRAGMA table_info(git_working_folders)") { columns.insert(Self.text($0, 1)) }
    for (name, definition) in [("tool", "TEXT NOT NULL DEFAULT ''"), ("discovery", "TEXT NOT NULL DEFAULT ''")] where !columns.contains(name) {
      try run("ALTER TABLE git_working_folders ADD COLUMN \(name) \(definition)")
    }
    try run("CREATE TABLE IF NOT EXISTS git_discovery_tombstones(hash TEXT PRIMARY KEY)")
    if try integer("SELECT count(*) FROM pragma_table_info('git_repositories') WHERE name='reopen_blocked'") == 0 {
      try run("ALTER TABLE git_repositories ADD COLUMN reopen_blocked INTEGER NOT NULL DEFAULT 0")
    }
    try run("CREATE INDEX IF NOT EXISTS git_folder_session ON git_working_folders(tool,session)")
  }
}

public struct GitBackfillReceipt {
  public let id: Int, device: Int, inode: Int, offset: Int
}
public struct GitBackfillPage {
  public var rows: [(id: Int, folder: GitWorkingFolder)] = []
  public var last: GitBackfillReceipt?
  /// Some rows were blanked because their source is still in metadata recovery.
  public var recoveryPending = false
}

public enum GitCommitFinish: Equatable {
  case complete, privacyRefused, retry
}
public enum GitReadFinish: Equatable {
  case accounted, interrupted, nativeFailure
}

public struct StoredGitRepository {
  public let id: Int
  public let directory: String
  public let needsRawDirectory: Bool
}

public struct GitPreparationPolicy {
  let generation: Int
  let retentionDays: Int
  let forgottenRevision: Int
}
extension ActivityStorage {
  private static func maskedGitText(_ value: String) -> String {
    // Preserve both existing masking layers, but run them before acquiring the writer.
    Redaction.apply(AgentLogEventParser.safeString(value)).text
  }
  public static func gitDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static func gitFolderKey(_ folder: GitWorkingFolder) -> String {
    let parts = [folder.tool?.rawValue ?? "", String(folder.device), String(folder.inode), folder.physicalSource.storedKey, AgentLogIdentityCodec.session(folder.session).storedKey, folder.folder]
    return Self.gitDigest(parts.map { "\($0.utf8.count):\($0)" }.joined())
  }
  fileprivate static func gitDiscoveryKey(_ folder: GitWorkingFolder) -> String {
    let safe = GitWorkingFolder(folder: AgentLogEventParser.safeString(folder.folder), session: AgentLogIdentityCodec.session(folder.session).storedKey,
      source: folder.physicalSource.storedKey, device: folder.device, inode: folder.inode, time: folder.time, tool: folder.tool, sourceIdentity: folder.physicalSource)
    return Self.gitDigest(Self.gitFolderKey(safe) + ":" + String(folder.time))
  }
  /// Re-polling a cursor is not a new cwd observation. The authority is a pure function
  /// of the checkpoint and hash-only receipt names: it reads no rows, so an append never
  /// depends on Git-queue writes to folders or the source revision.
  func gitCheckpointState(_ position: LogPosition, fallback: SQLValue, tool: AgentLogTool? = nil) throws -> SQLValue {
    guard var state = try? AgentLogState.decode(position.state), let tool = state.tool.flatMap(AgentLogTool.init(rawValue:)) ?? tool else { return fallback }
    state.tool = tool.rawValue
    state.gitOwnershipAuthority = ownLogSources().authority(path: position.path,
      sessions: [state.cwdSession, state.session, state.ownershipSession, state.ownedSession].compactMap { $0 }, tool: tool)
    return .maskedText(try state.encoded())
  }
  private func storedGitLogPosition(source: String) throws -> LogPosition? {
    var result: LogPosition?
    try connection.namedRows("SELECT * FROM log_positions WHERE path=?", [.key(source)]) {
      result = LogPosition(path: source, device: try $0.int("device"), inode: try $0.int("inode"),
        offset: try $0.int("offset"), state: try $0.text("state"), seenAt: try $0.int("seen_ts"))
    }
    return result
  }
  /// Opening a read-only connection is about a fifth of a validation. Inside `body` this
  /// thread's validations share one; each still reads in its own fresh transaction.
  public func withGitSourceSnapshot<T>(_ body: () throws -> T) throws -> T {
    let key = gitSnapshotKey
    if Thread.current.threadDictionary[key] != nil { return try body() }
    Thread.current.threadDictionary[key] = try openGitSourceSnapshot()
    defer { Thread.current.threadDictionary.removeObject(forKey: key) }
    return try body()
  }
  private func openGitSourceSnapshot() throws -> ActivityStorage {
    locked { gitSourceSnapshotOpens += 1 }
    return try ActivityStorage(url: url, appDataDirectory: appDataDirectory, readOnly: true, databaseScope: databaseScope)
  }
  private func prepareGitSource(_ folder: GitWorkingFolder, position: LogPosition?) throws -> GitSourcePreparation {
    let snapshot = try Thread.current.threadDictionary[gitSnapshotKey] as? ActivityStorage ?? openGitSourceSnapshot()
    return try snapshot.connection.transaction(write: false) {
      var prepared = GitSourcePreparation(revision: try snapshot.gitSourceRevision())
      prepared.candidates = [AgentLogIdentityCodec.session(folder.session)]
      let registry = ownLogSources()
      for checkpoint in [try snapshot.storedGitLogPosition(source: folder.physicalSource.storedKey), position].compactMap({ $0 })
        where checkpoint.device == folder.device && checkpoint.inode == folder.inode {
        guard let state = try? AgentLogState.decode(checkpoint.state) else { prepared.recovery = true; continue }
        prepared.recovery = prepared.recovery || state.metadataRecoveryOffset != nil
        guard let tool = folder.tool, state.tool == tool.rawValue else { continue }
        prepared.authority += state.gitOwnershipAuthority ?? []
        prepared.candidates += [state.session, state.ownershipSession, state.ownedSession].compactMap { $0 }
        if let session = state.ownedSession {
          let identity = session
          if !identity.storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prepared.own = true; prepared.provenance.append((tool, identity))
          }
        }
        prepared.own = prepared.own || state.ownWorkingFolder == true || state.ignoredSession == .ownWindow
      }
      if let tool = folder.tool {
        var retained: [String] = prepared.authority
        try snapshot.connection.namedRows("""
          SELECT ownership_authority FROM git_working_folders WHERE identity=? OR
            (source=? AND device=? AND inode=? AND session=? AND folder=? AND tool=?)
          """, [.key(Self.gitFolderKey(folder)), .key(folder.physicalSource.storedKey),
            .integer(folder.device), .integer(folder.inode), .key(AgentLogIdentityCodec.session(folder.session).storedKey),
            .maskedText(Self.maskedGitText(folder.folder)), .key(tool.rawValue)]) {
          let existing = try $0.text("ownership_authority")
          if !existing.isEmpty { retained += try JSONDecoder().decode([String].self, from: Data(existing.utf8)) }
        }
        if retained.isEmpty && (folder.sourceIdentity != nil || ["[secret]", "[redacted]", "[email]"].contains(where: folder.source.contains)) {
          // Masked legacy paths cannot prove the original path/home receipt set.
          prepared.recovery = true
        } else {
          prepared.authority = Array(Set(retained + (folder.sourceIdentity == nil ? registry.authority(path: folder.source, sessions: prepared.candidates, tool: tool) : []))).sorted()
          prepared.own = try prepared.own || registry.containsAuthority(prepared.authority)
        }
      }
      return prepared
    }
  }
  func gitOwnership(_ folder: GitWorkingFolder, prepared: GitSourcePreparation) throws -> (own: Bool, sessions: [(AgentLogTool, AgentLogSessionSubject)]) {
    // A missing tool is ambiguous, never agreement with either receipt namespace.
    guard let tool = folder.tool else { return (false, []) }
    var own = prepared.own
    var provenance = prepared.provenance
    let registry = ownLogSources()
    own = try own || (!prepared.authority.isEmpty && registry.containsAuthority(prepared.authority))
      || (folder.sourceIdentity == nil && registry.contains(path: folder.source, tool: tool))
    for session in prepared.candidates where !session.storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      if try connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE tool=? AND session_id=?",
        [.key(tool.rawValue), .key(session)]) > 0 || registry.containsSession(session, tool: tool) {
        own = true
        provenance.append((tool, session))
      }
    }
    own = try own || ownLogSourceKnown(LogPosition(path: folder.source, device: folder.device,
      inode: folder.inode, offset: 0, state: "", seenAt: folder.time), tool: tool)
    return (own, provenance)
  }
  func gitSourceAllowed(_ folder: GitWorkingFolder, prepared: GitSourcePreparation, discovery: String) throws -> Bool {
    guard let revision = prepared.revision, folder.tool != nil,
      !folder.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    guard !prepared.recovery, try !gitOwnership(folder, prepared: prepared).own else { return false }
    guard try gitSourceRevision() == revision else { throw StorageError.busy("Git source metadata changed; retry preparation") }
    return try connection.integer("SELECT count(*) FROM git_discovery_tombstones WHERE hash=?", [.key(discovery)]) == 0
  }
  public func validateGitObservation(_ folder: GitWorkingFolder, now: Int, position: LogPosition? = nil) throws -> Bool {
    let discovery = Self.gitDiscoveryKey(folder)
    let prepared = try prepareGitSource(folder, position: position)
    try beforeGitSourcePublication?()
    return try gitLocked { try connection.transaction {
      guard try gitSourceRevision() == prepared.revision else { throw StorageError.busy("Git source metadata changed; retry preparation") }
      let ownership = try gitOwnership(folder, prepared: prepared)
      if ownership.own, let tool = folder.tool {
        for (tool, session) in ownership.sessions { try purgeOwnLogSession(session, tool: tool) }
        try connection.run("INSERT OR IGNORE INTO agent_log_tool_own_sources VALUES(?,?,?,?)",
          [.key(tool.rawValue), .integer(folder.device), .integer(folder.inode), .key(folder.physicalSource.storedKey)])
        for key in legacyLogAdapter.sourceKeys(path: folder.source) {
          try purgeOwnLogSource(LogPosition(path: folder.source, device: folder.device, inode: folder.inode, offset: 0, state: "", seenAt: now), tool: tool, sourceKey: key)
        }
        return false
      }
      let context = GitDiscoveryPublication(folder: folder, source: prepared, discovery: discovery,
        policy: try gitPreparationPolicy(), phase: .touchValidation)
      return try gitDiscoveryPermitted(context, now: now)
    } }
  }
  public func setGitSecureInput(_ reading: @escaping () -> Bool?) {
    lock.lock(); defer { lock.unlock() }
    gitSecureInput = reading
  }
  func gitHistoricalRecordingAllowed(_ time: Int) throws -> Bool {
    var allowed = false
    try connection.namedRows("SELECT enabled,CAST(paused_until AS TEXT) AS pause FROM log_recording_history WHERE since<=? ORDER BY since DESC,id DESC LIMIT 1", [.integer(time)]) {
      allowed = try $0.int("enabled") != 0 && ($0.optionalText("pause").flatMap(Int.init) ?? Int.min) <= time
    }
    return allowed
  }
  public func gitRecordingAllowed(at now: Int) throws -> Bool {
    try gitLocked {
      let current = try settings()
      return try gitSecureInputIsClear() && current.recordingEnabled && (current.pausedUntil ?? Int.min) <= now && gitHistoricalRecordingAllowed(now)
    }
  }
  // Called under the storage lock, including asynchronous Git read checks.
  private func gitSecureInputIsClear() -> Bool {
    let clear = gitSecureInput() == false
    if !clear { gitSecureInputRefusalEpoch &+= 1 }
    return clear
  }
  public func gitSecureInputDeferralRevision() -> UInt64 {
    lock.lock(); defer { lock.unlock() }
    return gitSecureInputRefusalEpoch
  }
  public func gitSecureInputDeferred() -> Bool {
    (try? gitLocked { !gitSecureInputIsClear() }) ?? true
  }
  public func gitObservationGeneration(now: Int) throws -> Int? {
    try gitLocked { try gitRecordingAllowed(at: now) ? gitPrivacyGeneration() : nil }
  }
  func gitAllowed(_ time: Int) throws -> Bool {
    guard time < Int.max else { return false }
    return try gitHistoricalRecordingAllowed(time) && !forgotten(TimeRange(time, time + 1))
  }
  public func knownGitFolder(_ folder: GitWorkingFolder, allowMaskedMatch: Bool = false) throws -> (id: Int, repo: Int?)? {
    let identity = Self.gitFolderKey(folder)
    let source = folder.physicalSource.storedKey
    let session = AgentLogIdentityCodec.session(folder.session).storedKey
    let masked = Self.maskedGitText(folder.folder)
    return try gitLocked {
      var result: (Int, Int?)?
      try connection.namedRows("""
        SELECT id,CAST(repo_id AS TEXT) AS repo FROM git_working_folders WHERE complete=1 AND (identity=? OR
        (?=1 AND source=? AND device=? AND inode=? AND session=? AND folder=? AND tool=?)) ORDER BY id LIMIT 1
        """, [.key(identity), .integer(allowMaskedMatch ? 1 : 0), .key(source), .integer(folder.device), .integer(folder.inode),
          .key(session), .maskedText(masked), .key(folder.tool?.rawValue ?? "")]) {
        result = (try $0.int("id"), try $0.optionalText("repo").flatMap(Int.init))
      }
      return result
    }
  }
  @discardableResult public func touchGitFolder(_ folder: GitWorkingFolder, id: Int, now: Int, position: LogPosition? = nil) throws -> Bool {
    try beforeGitTouch?()
    let discovery = Self.gitDiscoveryKey(folder)
    let prepared = try prepareGitSource(folder, position: position)
    let context = GitDiscoveryPublication(folder: folder, source: prepared, discovery: discovery,
      policy: try gitPreparationPolicy(), phase: .touch(id))
    let authority = String(decoding: try JSONEncoder().encode(prepared.authority), as: UTF8.self)
    return try publishGit(.discovery(context), now: now) {
      try connection.run("UPDATE git_working_folders SET last_seen=max(last_seen,?),ownership_authority=? WHERE id=? AND (last_seen<? OR ownership_authority!=?)",
        [.integer(folder.time), .key(authority), .integer(id), .integer(folder.time), .key(authority)])
    }.value != nil
  }
  public func gitShouldResolve(_ folder: GitWorkingFolder, now: Int, position: LogPosition? = nil) throws -> Bool {
    let prepared = try prepareGitSource(folder, position: position)
    let context = GitDiscoveryPublication(folder: folder, source: prepared, discovery: Self.gitDiscoveryKey(folder),
      policy: try gitPreparationPolicy(), phase: .register(Self.gitFolderKey(folder)))
    return try gitLocked { try gitDiscoveryPermitted(context, now: now) }
  }
  public func rememberGitFolder(_ folder: GitWorkingFolder, location: GitRepositoryLocation?, status: String, now: Int, position: LogPosition? = nil,
    preparedBranch: GitMaskedText? = nil, preparationGeneration: Int? = nil, preparationPolicy: GitPreparationPolicy? = nil) throws {
    try checkGitCancellation()
    let folderIdentity = Self.gitFolderKey(folder), discovery = Self.gitDiscoveryKey(folder)
    try gitLocked {
      gitFolderPreparations[folderIdentity] = GitFolderPreparation(cancellation: Thread.current.threadDictionary[gitCancellationKey] as? GitTaskCancellation)
    }
    defer { try? gitLocked {
      _ = gitFolderPreparations.removeValue(forKey: folderIdentity)
    } }
    let source = folder.physicalSource.storedKey, session = AgentLogIdentityCodec.session(folder.session).storedKey
    let maskedFolder = Self.maskedGitText(folder.folder)
    let common = Self.maskedGitText(location?.commonDirectory ?? "")
    let top = Self.maskedGitText(location?.topLevel ?? "")
    let branch = try preparedBranch?.smallText() ?? (preparedBranch == nil ? Self.maskedGitText(location?.branch ?? "") : "")
    let head = Self.maskedGitText(location?.head ?? "")
    let identity = location.map { Self.gitDigest($0.commonDirectory) }
    let maskedStatus = Redaction.apply(status).text
    let generation = try preparationGeneration ?? gitLocked { try gitPrivacyGeneration() }
    let policy = try preparationPolicy ?? gitPreparationPolicy()
    try discardGitFolderPreparation(identity: folderIdentity)
    let prepared = try prepareGitSource(folder, position: position)
    guard generation == policy.generation else { return }
    let context = GitDiscoveryPublication(folder: folder, source: prepared, discovery: discovery,
      policy: policy, phase: .register(folderIdentity))
    let publication = try publishGit(.discovery(context), now: now) { () throws -> (Int, Int?) in
      var repo: SQLValue = .null
      if let identity {
        try connection.run("INSERT OR IGNORE INTO git_repositories(identity,common_dir,ts,reopen_blocked) VALUES(?,?,?,?)",
          [.key(identity), .maskedText(common), .integer(folder.time),
            .integer(0)])
        repo = .integer(try connection.integer("SELECT id FROM git_repositories WHERE identity=?", [.key(identity)]))
      }
      try connection.run("""
        INSERT INTO git_working_folders(identity,source,device,inode,session,folder,repo_id,top_level,branch,head,ts,last_seen,attempt_ts,status,failures,tool,discovery,complete,ownership_authority)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(identity) DO UPDATE SET
        repo_id=excluded.repo_id,top_level=excluded.top_level,branch=excluded.branch,head=excluded.head,
        attempt_ts=excluded.attempt_ts,status=excluded.status,failures=CASE WHEN excluded.status='unversioned' THEN 0 ELSE git_working_folders.failures+excluded.failures END,complete=excluded.complete,ownership_authority=excluded.ownership_authority
        """, [.key(folderIdentity), .key(source), .integer(folder.device), .integer(folder.inode),
          .key(session), .maskedText(maskedFolder), repo, .maskedText(top),
          .maskedText(branch), .maskedText(head), .integer(folder.time), .integer(folder.time),
          .integer(now), .maskedText(maskedStatus), .integer(status == "failed" ? 1 : 0), .key(folder.tool?.rawValue ?? ""), .key(discovery),
          .integer((preparedBranch?.byteCount ?? 0) > 65536 ? 0 : 1),
          .key(String(decoding: try JSONEncoder().encode(prepared.authority), as: UTF8.self))])
      let id = try connection.integer("SELECT id FROM git_working_folders WHERE identity=?", [.key(folderIdentity)])
      return (id, try gitSourceRevision())
    }.value
    guard let publication, let preparedBranch, preparedBranch.byteCount > 65536 else { return }
    var state: GitWorkState = .admitted
    defer { if state != .complete { try? discardGitFolderPreparation(identity: folderIdentity) } }
    try afterGitFolderStarted?(publication.0)
    var chunkContext = context
    chunkContext.source.revision = publication.1
    chunkContext.phase = .branch(publication.0)
    var ordinal = 0
    try preparedBranch.forEachChunk { bytes in
      guard case .admitted = try publishGit(.discovery(chunkContext), now: now, {
        try connection.run("INSERT INTO git_value_text(kind,owner_id,field,ordinal,payload) VALUES(4,?,0,?,?)",
          [.integer(publication.0), .integer(ordinal), .maskedBlob(bytes)])
      }) else { throw StorageError.busy("Git folder preparation interrupted") }
      ordinal += 1; try gitUnit("branch"); Thread.sleep(forTimeInterval: 0.001)
    }
    try beforeGitFolderCompletion?()
    chunkContext.phase = .complete(publication.0)
    guard case .admitted = try publishGit(.discovery(chunkContext), now: now, {
      try connection.run("UPDATE git_working_folders SET complete=1 WHERE id=?", [.integer(publication.0)])
    }) else { throw StorageError.busy("Git folder preparation interrupted") }
    state = .complete
  }
  private func discardGitFolderPreparation(identity: String) throws {
    let id = try gitLocked { try gitTransaction(cleanup: true) { () throws -> Int in
      let id = try connection.integer("SELECT COALESCE(max(id),0) FROM git_working_folders WHERE identity=? AND complete!=1", [.key(identity)])
      if id != 0 { try connection.run("UPDATE git_working_folders SET complete=-1 WHERE id=? AND complete!=1", [.integer(id)]) }
      return id
    } }
    guard id != 0 else { return }
    while try gitLocked({ () throws -> Bool in
      try checkGitCleanup()
      try connection.run("DELETE FROM git_value_text WHERE id IN (SELECT id FROM git_value_text WHERE kind=4 AND owner_id=? AND EXISTS(SELECT 1 FROM git_working_folders WHERE id=? AND complete=-1) LIMIT 16)", [.integer(id), .integer(id)])
      return sqlite3_changes(connection.handle) > 0
    }) { try gitCleanupUnit("branch-cleanup"); Thread.sleep(forTimeInterval: 0.001) }
    try gitLocked { try gitTransaction(cleanup: true) {
      try connection.run("DELETE FROM git_working_folders WHERE id=? AND complete=-1", [.integer(id)])
      try cleanGitOrphans()
    } }
  }
  /// Read-only: the last resolution of a folder that is not linked to a repository.
  public func gitUnlinkedFolderState(_ folder: GitWorkingFolder) throws -> (status: String, failures: Int, attempt: Int)? {
    let source = folder.physicalSource.storedKey, session = AgentLogIdentityCodec.session(folder.session).storedKey
    let masked = Self.maskedGitText(folder.folder)
    return try gitLocked {
      var result: (String, Int, Int)?
      try connection.namedRows("""
        SELECT status,failures,attempt_ts FROM git_working_folders WHERE complete=1 AND repo_id IS NULL AND (identity=? OR
        (source=? AND device=? AND inode=? AND session=? AND folder=? AND tool=?)) ORDER BY id LIMIT 1
        """, [.key(Self.gitFolderKey(folder)), .key(source), .integer(folder.device), .integer(folder.inode),
          .key(session), .maskedText(masked), .key(folder.tool?.rawValue ?? "")]) {
        result = (try $0.text("status"), try $0.int("failures"), try $0.int("attempt_ts"))
      }
      return result
    }
  }
  /// Keyset paging keeps backfill independent of the number of saved log occurrences.
  /// The stored keys of checkpoints in metadata recovery.
  public func gitMetadataRecoverySources() throws -> Set<String> {
    try gitLocked {
      var keys = Set<String>()
      try connection.namedRows("SELECT path FROM log_positions INDEXED BY log_positions_git_recovery WHERE json_valid(state) AND json_extract(state,'$.metadataRecoveryOffset') IS NOT NULL") {
        keys.insert(try $0.text("path"))
      }
      return keys
    }
  }
  public func gitMetadataRecoveryPending() throws -> Bool {
    try gitLocked { try connection.integer("SELECT EXISTS(SELECT 1 FROM log_positions INDEXED BY log_positions_git_recovery WHERE json_valid(state) AND json_extract(state,'$.metadataRecoveryOffset') IS NOT NULL)") > 0 }
  }
  public func nextGitBackfill(after id: Int, checkpoints: Bool, now: Int) throws -> (Int, GitWorkingFolder)? {
    try gitBackfillPage(after: id, limit: 1, checkpoints: checkpoints, now: now).rows.first
  }
  public func nextGitSourceBackfill(after id: Int, position: LogPosition) throws -> (Int, GitWorkingFolder)? {
    try gitBackfillPage(after: id, limit: 1, checkpoints: false, now: position.seenAt, source: position).rows.first
  }
  /// One read snapshot per bounded page, in id order.
  /// Checkpoint pages read only checkpoints written after `since` (seen_ts).
  public func gitBackfillPage(after id: Int, limit: Int, checkpoints: Bool, now: Int, source: LogPosition? = nil, since: Int = Int.min) throws -> GitBackfillPage {
    let snapshot = try ActivityStorage(url: url, appDataDirectory: appDataDirectory, readOnly: true, databaseScope: databaseScope)
    return try snapshot.connection.transaction(write: false) {
      try snapshot.gitBackfillPageSnapshot(after: id, limit: limit, checkpoints: checkpoints, now: now, source: source, since: since)
    }
  }
  private func gitBackfillPageSnapshot(after id: Int, limit: Int, checkpoints: Bool, now: Int, source: LogPosition?, since: Int) throws -> GitBackfillPage {
    try gitLocked {
      var page = GitBackfillPage()
      var query = checkpoints
        ? "SELECT rowid AS id,path AS source,device,inode,state,seen_ts AS ts,0 AS byte_offset FROM log_positions WHERE rowid>? AND seen_ts>? ORDER BY rowid LIMIT ?"
        : "SELECT e.id,e.source,e.device,e.inode,e.byte_offset,COALESCE(s.session_id,h.session_id,e.session_id) AS session,CASE WHEN json_valid(p.payload) THEN COALESCE(json_extract(p.payload,'$.cwd'),json_extract(p.payload,'$.payload.cwd')) WHEN EXISTS(SELECT 1 FROM log_positions l WHERE l.path=e.source AND l.device=e.device AND l.inode=e.inode AND json_valid(l.state) AND json_extract(l.state,'$.cwdObservedAt')=e.ts AND json_extract(l.state,'$.project')=e.project) THEN e.project ELSE '' END AS folder,e.ts,e.tool FROM agent_log_events e JOIN agent_log_payloads p ON p.id=e.payload_id LEFT JOIN agent_log_event_sessions s ON s.event_id=e.id LEFT JOIN agent_log_inherited_sessions h ON h.event_id=e.id WHERE e.id>? AND e.timestamp_known=1 ORDER BY e.id LIMIT ?"
      var values: [SQLValue] = [.integer(id)] + (checkpoints ? [.integer(since)] : [])
      if let source {
        guard let tool = try AgentLogState.decode(source.state).tool else { return page }
        let keys = legacyLogAdapter.sourceKeys(path: source.path)
        let condition = " AND e.tool=? AND e.device=? AND e.inode=? AND e.source IN (" + Array(repeating: "?", count: keys.count).joined(separator: ",") + ")"
        query = query.replacingOccurrences(of: " ORDER BY e.id", with: condition + " ORDER BY e.id")
        values += [.key(tool), .integer(source.device), .integer(source.inode)] + keys.map(SQLValue.key)
      }
      values.append(.integer(max(1, limit)))
      var checkpointsBySource: [String: LogPosition?] = [:]
      try connection.namedRows(query, values) { row in
        var folder = "", session = "", tool: AgentLogTool?, time = try row.int("ts")
        if checkpoints {
          let state = try AgentLogState.decode(row.text("state"))
          if state.metadataRecoveryOffset == nil && state.ownWorkingFolder != true && state.ignoredSession != .ownWindow, let nativeTime = state.cwdObservedAt {
            folder = state.project; session = (state.cwdSession ?? state.session)?.storedKey ?? ""
            tool = state.tool.flatMap(AgentLogTool.init(rawValue:)); time = nativeTime
          }
        } else { folder = try row.text("folder"); session = try row.optionalText("session") ?? ""; tool = AgentLogTool(rawValue: try row.text("tool")) }
        let rowSource = try row.text("source")
        if checkpointsBySource[rowSource] == nil { checkpointsBySource[rowSource] = .some(try storedGitLogPosition(source: rowSource)) }
        if let checkpoint = checkpointsBySource[rowSource] ?? nil,
          checkpoint.device == (try row.int("device")), checkpoint.inode == (try row.int("inode")),
          try AgentLogState.decode(checkpoint.state).metadataRecoveryOffset != nil { folder = ""; page.recoveryPending = true }
        page.rows.append((try row.int("id"), GitWorkingFolder(folder: folder, session: session,
          source: source?.path ?? rowSource, device: try row.int("device"), inode: try row.int("inode"), time: time, tool: tool, sourceIdentity: source == nil ? AgentLogIdentityCodec.physical(rowSource) : nil)))
        page.last = GitBackfillReceipt(id: try row.int("id"), device: try row.int("device"), inode: try row.int("inode"), offset: try row.int("byte_offset"))
      }
      return page
    }
  }
  private func gitBackfillKey(_ source: LogPosition?) throws -> String? {
    guard let source else { return "stored-events" }
    guard let tool = try AgentLogState.decode(source.state).tool else { return nil }
    return Self.gitDigest([tool, String(source.device), String(source.inode), source.path].map { "\($0.utf8.count):\($0)" }.joined())
  }
  /// Retained occurrences above the mark still need a discovery offer. Nil source is the stored-event pass.
  public func gitBackfillProgress(_ source: LogPosition?) throws -> Int {
    guard let key = try gitBackfillKey(source) else { return 0 }
    return try gitLocked { try connection.integer("SELECT COALESCE(max(event_id),0) FROM git_backfill_progress WHERE source=?", [.key(key)]) }
  }
  /// The mark advances only while the last offered occurrence still exists with
  /// the same identity; a deleted and reused rowid leaves the mark where it was.
  public func saveGitBackfillProgress(_ receipt: GitBackfillReceipt, source: LogPosition?) throws {
    guard let key = try gitBackfillKey(source) else { return }
    try gitLocked { try gitTransaction(cleanup: true) {
      guard try connection.integer("SELECT count(*) FROM agent_log_events WHERE id=? AND device=? AND inode=? AND byte_offset=?",
        [.integer(receipt.id), .integer(receipt.device), .integer(receipt.inode), .integer(receipt.offset)]) == 1 else { return }
      try connection.run("INSERT INTO git_backfill_progress(source,event_id) VALUES(?,?) ON CONFLICT(source) DO UPDATE SET event_id=max(event_id,excluded.event_id)",
        [.key(key), .integer(receipt.id)])
    } }
  }
  /// A finished receipt says every retained occurrence of the source below its offset
  /// was offered. Only new events move the offset, so a receipt never skips one. The
  /// value lives in the key because the clamp trigger lowers event_id.
  public func gitBackfillFinishedKey(_ source: LogPosition) throws -> String? {
    guard source.offset > 0, let key = try gitBackfillKey(source) else { return nil }
    return "finished:" + key + ":" + String(source.offset)
  }
  public func gitBackfillFinishedReceipts() throws -> Set<String> {
    try gitLocked {
      var keys = Set<String>()
      try connection.namedRows("SELECT source FROM git_backfill_progress WHERE source>='finished:' AND source<'finished;'") { keys.insert(try $0.text("source")) }
      return keys
    }
  }
  /// Replaces the source's earlier receipt, so there is at most one per source.
  public func saveGitBackfillFinished(_ source: LogPosition) throws {
    guard let key = try gitBackfillKey(source), let receipt = try gitBackfillFinishedKey(source) else { return }
    try gitLocked { try gitTransaction(cleanup: true) {
      try connection.run("DELETE FROM git_backfill_progress WHERE source>? AND source<? AND source!=?",
        [.key("finished:" + key + ":"), .key("finished:" + key + ";"), .key(receipt)])
      try connection.run("INSERT OR IGNORE INTO git_backfill_progress(source,event_id) VALUES(?,0)", [.key(receipt)])
    } }
  }
  /// Checkpoints with a later seen_ts are offered again. An unchanged checkpoint keeps
  /// its seen_ts, so a restart reads only checkpoints written since the last complete pass.
  public func gitCheckpointBackfillMark() throws -> Int {
    try gitLocked { try gitCheckpointMark() ?? Int.min }
  }
  /// Caller holds the storage lock. Nil before Git adoption or before a complete pass.
  /// With `floor`, the time of a started pass counts too, for checkpoint writers.
  func gitCheckpointMark(floor: Bool = false) throws -> Int? {
    guard try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='git_backfill_progress'") > 0 else { return nil }
    var mark: Int?
    try connection.namedRows("SELECT source FROM git_backfill_progress WHERE source>='checkpoints:' AND source<'checkpoints;'") {
      let key = try $0.text("source").dropFirst("checkpoints:".count)
      if let value = Int(key) ?? (floor && key.hasPrefix("floor:") ? Int(key.dropFirst("floor:".count)) : nil) { mark = max(mark ?? value, value) }
    }
    return mark
  }
  /// Saved before a checkpoint pass reads its first page. Every checkpoint written after
  /// this, at any clock, gets a seen_ts above `now`, and so above the mark the pass saves;
  /// one written before it is in the pass's pages. Saving the mark removes the floor.
  public func startGitCheckpointPass(_ now: Int) throws {
    try gitLocked { try gitTransaction(cleanup: true) {
      try connection.run("DELETE FROM git_backfill_progress WHERE source>='checkpoints:floor:' AND source<'checkpoints:floor;'")
      try connection.run("INSERT INTO git_backfill_progress(source,event_id) VALUES(?,0)", [.key("checkpoints:floor:" + String(now))])
    } }
  }
  public func saveGitCheckpointBackfillMark(_ seen: Int) throws {
    try gitLocked { try gitTransaction(cleanup: true) {
      try connection.run("DELETE FROM git_backfill_progress WHERE source>='checkpoints:' AND source<'checkpoints;'")
      try connection.run("INSERT INTO git_backfill_progress(source,event_id) VALUES(?,0)", [.key("checkpoints:" + String(seen))])
    } }
  }
  /// Read-only hint for batching equal occurrences. Publication still decides every write.
  public func gitFolderOccurrence(_ folder: GitWorkingFolder, allowMaskedMatch: Bool) throws -> (linked: Bool, attempt: Int?) {
    let linked = try knownGitFolder(folder, allowMaskedMatch: allowMaskedMatch)?.repo != nil
    let attempt: Int? = try gitLocked {
      var attempt: Int?
      try connection.namedRows("SELECT attempt_ts FROM git_working_folders WHERE identity=?", [.key(Self.gitFolderKey(folder))]) { attempt = try $0.int("attempt_ts") }
      return attempt
    }
    return (linked, attempt)
  }
  /// Read-only preflight for batching: a source whose ownership receipts cannot be proven
  /// is refused by validation at every occurrence time. Own sources answer false so their
  /// purge still runs through validation.
  public func gitOccurrenceUnattributable(_ folder: GitWorkingFolder, position: LogPosition?) throws -> Bool {
    let prepared = try prepareGitSource(folder, position: position)
    guard prepared.recovery else { return false }
    return try gitLocked { try !gitOwnership(folder, prepared: prepared).own }
  }
  /// A checkpoint still in metadata recovery cannot attribute its retained occurrences yet.
  public func gitSourceRecoveryPending(_ source: LogPosition) throws -> Bool {
    if (try? AgentLogState.decode(source.state))?.metadataRecoveryOffset != nil { return true }
    return try gitLocked {
      for key in legacyLogAdapter.sourceKeys(path: source.path) {
        if let checkpoint = try storedGitLogPosition(source: key.storedKey), checkpoint.device == source.device, checkpoint.inode == source.inode,
          (try? AgentLogState.decode(checkpoint.state))?.metadataRecoveryOffset != nil { return true }
      }
      return false
    }
  }
  public func nextGitFolder(after id: Int) throws -> (Int, GitWorkingFolder, Int?)? {
    try gitLocked {
      var result: (Int, GitWorkingFolder, Int?)?
      try connection.namedRows("SELECT *,CASE WHEN complete=1 THEN CAST(repo_id AS TEXT) END AS repo FROM git_working_folders WHERE id>? ORDER BY id LIMIT 1", [.integer(id)]) { row in
        result = (try row.int("id"), GitWorkingFolder(folder: try row.text("folder"), session: try row.text("session"),
          source: try row.text("source"), device: try row.int("device"), inode: try row.int("inode"), time: try row.int("ts"), tool: AgentLogTool(rawValue: try row.text("tool")), sourceIdentity: AgentLogIdentityCodec.physical(try row.text("source"))),
          try row.optionalText("repo").flatMap(Int.init))
      }
      return result
    }
  }
  /// Everything a discovery visit consults besides the folder's own row and checkpoint:
  /// ownership receipts, recording settings and history, forgotten ranges, the retention
  /// day and tombstones. Not the source revision: any event or checkpoint write bumps it,
  /// and a visit uses it only to retry a preparation that raced a write.
  /// Nil when ownership cannot be fingerprinted.
  public func gitDiscoveryRevision(now: Int) throws -> String? {
    guard let ownership = try agentLogOwnershipRevision() else { return nil }
    return try gitLocked {
      let policy = try gitPreparationPolicy(), settings = try settings()
      var parts = [ownership, String(policy.generation), String(policy.retentionDays), String(policy.forgottenRevision),
        settings.recordingEnabled ? "1" : "0", settings.pausedUntil.map(String.init) ?? "-",
        String(Int((Double(try gitRetentionCutoff(now: now)) / 86400).rounded(.down)))]
      parts += [String(try connection.integer("SELECT count(*) FROM forgotten_ranges")),
        String(try connection.integer("SELECT count(*) FROM log_recording_history")),
        String(try connection.integer("SELECT count(*) FROM git_discovery_tombstones")),
        String(try connection.integer("SELECT COALESCE(max(rowid),0) FROM git_discovery_tombstones"))]
      try connection.namedRows("SELECT id,since,enabled,CAST(paused_until AS TEXT) AS pause FROM log_recording_history ORDER BY id DESC LIMIT 1") {
        parts += [String(try $0.int("id")), String(try $0.int("since")), String(try $0.int("enabled")), try $0.optionalText("pause") ?? "-"]
      }
      return parts.joined(separator: "|")
    }
  }
  /// A one-way digest of a folder row, every column, and of its source's checkpoint row.
  /// It holds no content. Nil when the row is gone.
  public func gitDiscoveryVisitDigest(id: Int, folder: GitWorkingFolder) throws -> String? {
    try gitLocked {
      var hash = SHA256(), found = false
      func add(_ statement: OpaquePointer) {
        for column in 0..<sqlite3_column_count(statement) {
          let type = sqlite3_column_type(statement, column)
          let count = type == SQLITE_NULL ? 0 : Int(sqlite3_column_bytes(statement, column))
          let bytes = sqlite3_column_blob(statement, column)
          var header = [UInt8(truncatingIfNeeded: type)] + withUnsafeBytes(of: UInt64(count).bigEndian) { Array($0) }
          if let bytes, count > 0 { header += Array(UnsafeRawBufferPointer(start: bytes, count: count)) }
          hash.update(data: Data(header))
        }
      }
      try connection.rows("SELECT * FROM git_working_folders WHERE id=?", [.integer(id)]) { found = true; add($0) }
      guard found else { return nil }
      hash.update(data: Data("|".utf8))
      try connection.rows("SELECT device,inode,offset,state,seen_ts FROM log_positions WHERE path=?", [.key(folder.physicalSource.storedKey)]) { add($0) }
      return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }
  public func gitFolderPresence(id: Int, exists: Bool, now: Int) throws {
    _ = try publishGit(.diagnostic(.folder(id)), now: now) {
      try connection.run("UPDATE git_working_folders SET status=? WHERE id=? AND repo_id IS NOT NULL AND complete=1",
        [.key(exists ? "ready" : "missing"), .integer(id)])
    }
  }
  public func gitRepositoryExists(_ id: Int) throws -> Bool {
    try gitLocked { try connection.integer("SELECT count(*) FROM git_repositories WHERE id=?", [.integer(id)]) == 1 }
  }
  public func gitFolderExists(_ id: Int) throws -> Bool {
    try gitLocked { try connection.integer("SELECT count(*) FROM git_working_folders WHERE id=?", [.integer(id)]) == 1 }
  }
  var collectibleGitRepository: String {
    "EXISTS(SELECT 1 FROM git_working_folders f WHERE f.repo_id=git_repositories.id AND \(gitPermittedSourcePredicate))"
  }
  public func nextGitRepository(after id: Int) throws -> StoredGitRepository? {
    try gitLocked {
      var result: StoredGitRepository?
      try connection.namedRows("SELECT id,common_dir,identity FROM git_repositories WHERE id>? AND \(collectibleGitRepository) ORDER BY id LIMIT 1", [.integer(id)]) {
        result = StoredGitRepository(id: try $0.int("id"), directory: try $0.text("common_dir"), needsRawDirectory: try $0.text("identity") != Self.gitDigest($0.text("common_dir")))
      }
      return result
    }
  }
  public func gitReopenBlocked(repo: Int, blocked: Bool, now: Int) throws {
    _ = try publishGit(.diagnostic(.repository(repo)), now: now) {
      try connection.run("UPDATE git_repositories SET reopen_blocked=? WHERE id=?",
        [.integer(blocked ? 1 : 0), .integer(repo)])
    }
  }
  func gitPrivacyGeneration() throws -> Int {
    try connection.integer("SELECT COALESCE(max(id),0) FROM log_recording_history")
  }
  public func prepareGitRefs(repo: Int, to file: FileHandle, now: Int) throws {
    try checkGitCancellation()
    try gitLocked {
      gitReads[repo] = GitReadPublication(policy: try gitPreparationPolicy(), preparedAt: now,
        state: .admitted, cancellation: Thread.current.threadDictionary[gitCancellationKey] as? GitTaskCancellation)
      try gitStageLocked {
        if gitStageCancellation?.isCancelled == true {
          try gitStageConnection?.close(); gitStageConnection = nil; gitStageCancellation = nil
        }
        if gitStageConnection == nil {
          gitStageConnection = try SQLiteConnection(url: url, readOnly: true, scope: databaseScope)
          gitStageCancellation = Thread.current.threadDictionary[gitCancellationKey] as? GitTaskCancellation
        }
        try gitStageConnection!.run("CREATE TEMP TABLE IF NOT EXISTS git_next_refs(repo_id INTEGER NOT NULL,identity TEXT NOT NULL,name TEXT NOT NULL,tip TEXT NOT NULL,PRIMARY KEY(repo_id,identity))")
        try gitStageConnection!.run("CREATE TEMP TABLE IF NOT EXISTS git_next_ref_text(repo_id INTEGER NOT NULL,identity TEXT NOT NULL,ordinal INTEGER NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(repo_id,identity,ordinal))")
      }
    }
    try clearGitRefStage(repo: repo)
    // Exporting a frontier can involve many refs and filesystem writes. A separate WAL
    // reader leaves the maintenance connection available to cwd discovery.
    let snapshot = try SQLiteConnection(url: url, readOnly: true, scope: databaseScope)
    if let cancellation = Thread.current.threadDictionary[gitCancellationKey] as? GitTaskCancellation {
      sqlite3_progress_handler(snapshot.handle, 1000, { context in
        guard let context else { return 0 }
        return Unmanaged<GitTaskCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
      }, Unmanaged.passUnretained(cancellation).toOpaque())
    }
    defer { sqlite3_progress_handler(snapshot.handle, 0, nil, nil) }
    try snapshot.namedRows("SELECT DISTINCT tip FROM git_refs WHERE repo_id=? AND frontier=(SELECT frontier FROM git_repositories WHERE id=?)", [.integer(repo), .integer(repo)]) {
      try checkGitCancellation()
      try file.write(contentsOf: Data(((try $0.text("tip")) + "\n").utf8))
      try gitUnit("frontier-export")
    }
  }
  public func stageGitRef(repo: Int, name: String, tip: String) throws {
    try stageGitRef(repo: repo, name: GitMaskedText.prepare(name, in: FileManager.default.temporaryDirectory),
      identity: Self.gitDigest(name), tip: tip)
  }
  public func stageGitRef(repo: Int, name: GitMaskedText, identity: String, tip: String) throws {
    try checkGitCancellation()
    let small = try name.smallText() ?? ""
    let now = try gitLocked { gitReads[repo]?.preparedAt }
    guard let now else { throw StorageError.busy("Git ref stage has no preparation receipt") }
    guard case .admitted = try publishGit(.frontier(.staging(repo)), now: now, {
      try gitStageLocked { try gitStage().run("INSERT OR REPLACE INTO git_next_refs VALUES(?,?,?,?)",
        [.integer(repo), .key(identity), .maskedText(small), .key(tip)]) }
    }) else { throw StorageError.busy("Git ref staging interrupted") }
    if name.byteCount <= 65536 { return }
    var ordinal = 0
    try name.forEachChunk { bytes in
      try checkGitCancellation()
      guard case .admitted = try publishGit(.frontier(.staging(repo)), now: now, {
        try gitStageLocked { try gitStage().run("INSERT OR REPLACE INTO git_next_ref_text VALUES(?,?,?,?)",
          [.integer(repo), .key(identity), .integer(ordinal), .maskedBlob(bytes)]) }
      }) else { throw StorageError.busy("Git ref staging interrupted") }
      ordinal += 1; try gitUnit("staging"); Thread.sleep(forTimeInterval: 0.001)
    }
  }
  private func gitStage() throws -> SQLiteConnection {
    try checkGitCancellation()
    guard let gitStageConnection else { throw StorageError.busy("Git ref stage discarded") }
    return gitStageConnection
  }
  /// TEMP has no durable privacy lineage. Closing its dedicated connection unlinks
  /// the entire staging file at stop, without walking the remaining payload pages.
  public func cancelGitStaging(_ cancellation: GitTaskCancellation) throws {
    try withGitCancellation(cancellation) {
      try gitStageLocked {
        guard gitStageCancellation === cancellation else { return }
        try gitStageConnection?.close()
        gitStageConnection = nil; gitStageCancellation = nil
      }
    }
  }
  private func clearGitRefStage(repo: Int) throws {
    for table in ["git_next_ref_text", "git_next_refs"] {
      while try gitStageLocked({ () throws -> Bool in
        try checkGitCancellation()
        guard let stage = gitStageConnection else { return false }
        try stage.run("DELETE FROM \(table) WHERE rowid IN (SELECT rowid FROM \(table) WHERE repo_id=? LIMIT 32)", [.integer(repo)])
        return sqlite3_changes(stage.handle) > 0
      }) { try gitUnit("staging-cleanup"); Thread.sleep(forTimeInterval: 0.001) }
    }
  }
  private func cleanGitFrontiers(repo: Int) throws {
    var cursor = 0
    while let id = try gitLocked({ () throws -> Int? in
      var id: Int?
      try connection.namedRows("SELECT id FROM git_refs WHERE repo_id=? AND id>? AND frontier!=(SELECT frontier FROM git_repositories WHERE id=?) AND frontier!=(SELECT pending_frontier FROM git_repositories WHERE id=?) ORDER BY id LIMIT 1",
        [.integer(repo), .integer(cursor), .integer(repo), .integer(repo)]) { id = try $0.int("id") }
      return id
    }) {
      try checkGitCleanup()
      cursor = id
      while try gitLocked({ () throws -> Bool in
        try checkGitCleanup()
        try connection.run("DELETE FROM git_value_text WHERE id IN (SELECT id FROM git_value_text WHERE kind=3 AND owner_id=? AND EXISTS(SELECT 1 FROM git_refs r JOIN git_repositories p ON p.id=r.repo_id WHERE r.id=? AND r.repo_id=? AND r.frontier!=p.frontier AND r.frontier!=p.pending_frontier) LIMIT 16)", [.integer(id), .integer(id), .integer(repo)])
        return sqlite3_changes(connection.handle) > 0
      }) { try gitCleanupUnit("frontier-cleanup"); Thread.sleep(forTimeInterval: 0.001) }
      try gitLocked { try connection.run("DELETE FROM git_refs WHERE id=? AND repo_id=? AND frontier!=(SELECT frontier FROM git_repositories WHERE id=?) AND frontier!=(SELECT pending_frontier FROM git_repositories WHERE id=?)", [.integer(id), .integer(repo), .integer(repo), .integer(repo)]) }
      try gitCleanupUnit("frontier-row-cleanup"); Thread.sleep(forTimeInterval: 0.001)
    }
  }
  public func finishGitRead(repo: Int, now: Int, succeeded: Bool, readFailure: Bool = false) throws {
    try finishGitRead(repo: repo, now: now, outcome: succeeded ? .accounted : readFailure ? .nativeFailure : .interrupted)
  }
  public func finishGitRead(repo: Int, now: Int, outcome: GitReadFinish) throws {
    defer { try? gitLocked {
      _ = gitReads.removeValue(forKey: repo)
    } }
    let frontier = UUID().uuidString
    defer {
      // Invalidate before disposal, including errors and task stop. The old active
      // pointer remains authoritative until the entire replacement is certified.
      try? gitLocked {
        try connection.run("UPDATE git_repositories SET pending_frontier='',pending_ref_count=0 WHERE id=? AND pending_frontier=?", [.integer(repo), .key(frontier)])
      }
      try? cleanGitFrontiers(repo: repo)
      if let cancellation = Thread.current.threadDictionary[gitCancellationKey] as? GitTaskCancellation, cancellation.isCancelled {
        try? cancelGitStaging(cancellation)
      } else { try? clearGitRefStage(repo: repo) }
    }
    if outcome != .accounted {
      try gitLocked { try connection.run("UPDATE git_repositories SET pending_frontier='',pending_ref_count=0 WHERE id=?", [.integer(repo)]) }
    }
    var cursor = ""
    var state: GitWorkState = .interrupted
    var published = 0
    if outcome == .accounted {
      let admission = try publishGit(.frontier(.begin(repo)), now: now) {
        try connection.run("UPDATE git_repositories SET pending_frontier=?,pending_ref_count=0 WHERE id=?", [.key(frontier), .integer(repo)])
      }
      if case .admitted = admission { state = .admitted }
    }
    while state == .admitted {
      let row: (String, String, String)? = try gitLocked {
        var next: (String, String, String)?
        try gitStageLocked { try gitStage().namedRows("SELECT identity,name,tip FROM git_next_refs WHERE repo_id=? AND identity>? ORDER BY identity LIMIT 1",
          [.integer(repo), .key(cursor)]) { next = (try $0.text("identity"), try $0.text("name"), try $0.text("tip")) } }
        return next
      }
      guard let row else { break }
      cursor = row.0
      let id = try publishGit(.frontier(.row(repo, frontier)), now: now) {
        try connection.run("INSERT INTO git_refs(repo_id,identity,name,tip,ts,frontier) VALUES(?,?,?,?,?,?)",
          [.integer(repo), .key(frontier + ":" + row.0), .maskedText(row.1), .key(row.2), .integer(now), .key(frontier)])
        return Int(sqlite3_last_insert_rowid(connection.handle))
      }.value
      guard let id else { state = .interrupted; break }
      published += 1
      var ordinal = -1
      while state == .admitted {
        try checkGitCancellation()
        let chunk: (Int, Data)? = try gitLocked {
          var result: (Int, Data)?
          try gitStageLocked { try gitStage().rows("SELECT ordinal,payload FROM git_next_ref_text WHERE repo_id=? AND identity=? AND ordinal>? ORDER BY ordinal LIMIT 1",
            [.integer(repo), .key(row.0), .integer(ordinal)]) { s in
            if let bytes = sqlite3_column_blob(s, 1) { result = (SQLiteConnection.int(s, 0), Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 1)))) }
          } }
          return result
        }
        guard let chunk else { break }
        let result = try publishGit(.frontier(.chunk(repo, frontier, id)), now: now) {
          try connection.run("INSERT INTO git_value_text(kind,owner_id,field,ordinal,payload) VALUES(3,?,0,?,?)",
            [.integer(id), .integer(chunk.0), .maskedBlob(chunk.1)])
        }
        guard case .admitted = result else { state = .interrupted; break }
        ordinal = chunk.0; try gitUnit("frontier"); Thread.sleep(forTimeInterval: 0.001)
      }
      try gitUnit("frontier-row"); Thread.sleep(forTimeInterval: 0.001)
    }
    try beforeGitFrontierPublication?()
    if state == .admitted {
      let result = try publishGit(.frontier(.certify(repo, frontier, published)), now: now) {
        try connection.run("UPDATE git_repositories SET last_read=?,frontier=?,pending_frontier='',pending_ref_count=0 WHERE id=?", [.integer(now), .key(frontier), .integer(repo)])
      }
      state = result.value != nil ? .complete : .interrupted
    } else if outcome == .nativeFailure {
      do {
        _ = try publishGit(.frontier(.nativeFailure(repo)), now: now) {
          try connection.run("UPDATE git_repositories SET failures=failures+1 WHERE id=?", [.integer(repo)])
        }
      } catch is CancellationError { return }
    }
  }
  public func gitCommitKnown(repo: Int, hash: String) throws -> Bool {
    try gitLocked {
      try connection.integer("SELECT EXISTS(SELECT 1 FROM git_tombstones WHERE hash=?) OR EXISTS(SELECT 1 FROM git_commits WHERE repo_id=? AND hash=? AND complete=1)",
        [.key(hash), .integer(repo), .key(hash)]) != 0
    }
  }
  public func gitPreparationGeneration(repo: Int, now: Int) throws -> Int? {
    try gitLocked {
      guard try gitRecordingAllowed(at: now),
        try connection.integer("SELECT count(*) FROM git_repositories WHERE id=? AND \(collectibleGitRepository)", [.integer(repo)]) == 1 else { return nil }
      return try gitPrivacyGeneration()
    }
  }
  /// Store the maintenance clock, rather than an irrevocable cutoff: expanding the
  /// retention policy must still permit legitimate historical backfill.
  func gitRetentionCutoff(now: Int) throws -> Int {
    let maintained = try connection.integer("SELECT COALESCE(max(maintained_at),?) FROM git_retention_progress", [.integer(now)])
    return try max(now, maintained) - settings().promptRetentionDays * 86400
  }
  public func gitPreparationPolicy() throws -> GitPreparationPolicy {
    try gitLocked { GitPreparationPolicy(generation: try gitPrivacyGeneration(), retentionDays: try settings().promptRetentionDays,
      forgottenRevision: try connection.integer("SELECT COALESCE(max(rowid),0) FROM forgotten_ranges")) }
  }
  public func gitPolicyAllowed(generation: Int, policy: GitPreparationPolicy, now: Int) throws -> Bool {
    try gitLocked {
      try generation == policy.generation && generation == gitPrivacyGeneration() && gitRecordingAllowed(at: now) && gitAllowed(now)
        && now >= gitRetentionCutoff(now: now)
        && settings().promptRetentionDays == policy.retentionDays
        && connection.integer("SELECT COALESCE(max(rowid),0) FROM forgotten_ranges") == policy.forgottenRevision
    }
  }
  /// The policy read before a backfill page still holds at `now`.
  public func gitPolicyAllowed(_ policy: GitPreparationPolicy, now: Int) throws -> Bool {
    try gitPolicyAllowed(generation: policy.generation, policy: policy, now: now)
  }
  /// Preparation may take longer than a Git I/O deadline. Privacy changes still stop it
  /// before the next bounded window; the publishing transaction repeats the final checks.
  public func gitPreparationAllowed(repo: Int, hash: String, generation: Int, policy: GitPreparationPolicy, now: Int) throws -> Bool {
    try gitLocked {
      try gitPolicyAllowed(generation: generation, policy: policy, now: now)
        && connection.integer("SELECT count(*) FROM git_tombstones WHERE hash=?", [.key(hash)]) == 0
        && connection.integer("SELECT count(*) FROM git_repositories WHERE id=? AND \(collectibleGitRepository)", [.integer(repo)]) == 1
    }
  }
  public func gitReadNeedsRetry(repo: Int) throws -> Bool {
    try gitLocked { gitReads[repo]?.state == .interrupted }
  }
  public func gitHashForgotten(_ hash: String) throws -> Bool {
    try gitLocked { try connection.integer("SELECT count(*) FROM git_tombstones WHERE hash=?", [.key(hash)]) > 0 }
  }
  public func beginGitCommit(repo: Int, commit: GitCommitRecord, now: Int, preparationGeneration: Int? = nil) throws -> Int? {
    let generation = try preparationGeneration ?? gitLocked { try gitPrivacyGeneration() }
    let policy = try gitPreparationPolicy()
    let fields = try [commit.author, commit.email, commit.message].map {
      try GitMaskedText.prepare($0, in: FileManager.default.temporaryDirectory)
    }
    return try beginGitCommit(repo: repo, prepared: GitPreparedMetadata(hash: commit.hash, authorTime: commit.authorTime,
      commitTime: commit.commitTime, fields: fields), generation: generation, now: now, preparationPolicy: policy)
  }
  private func publishGitCommit(repo: Int, commit: GitCommitRecord, generation: Int, policy: GitPreparationPolicy, author: String, email: String, message: String, now: Int) throws -> Int? {
    let receipt = GitCommitPublication(repo: repo, hash: commit.hash, generation: generation, policy: policy,
      authorTime: commit.authorTime, commitTime: commit.commitTime,
      cancellation: Thread.current.threadDictionary[gitCancellationKey] as? GitTaskCancellation)
    return try publishGit(.commitParent(receipt), now: now) {
      // A failed/interrupted file stream is retried without advancing its ref frontier.
      gitCommitReads = gitCommitReads.filter { $0.value.repo != repo || $0.value.hash != commit.hash }
      guard try connection.integer("SELECT count(*) FROM git_commits WHERE repo_id=? AND hash=? AND complete!=1", [.integer(repo), .key(commit.hash)]) == 0 else { throw StorageError.busy("Git commit disposal pending") }
      try connection.run("INSERT INTO git_commits(repo_id,hash,author_ts,ts,author,email,message) VALUES(?,?,?,?,?,?,?)",
        [.integer(repo), .key(commit.hash), .integer(commit.authorTime), .integer(commit.commitTime),
          .maskedText(author), .maskedText(email), .maskedText(message)])
      let id = Int(sqlite3_last_insert_rowid(connection.handle))
      var admitted = receipt; admitted.state = .admitted
      gitCommitReads[id] = admitted
      return id
    }.value
  }
  /// Large fields live in bounded chunks; the parent remains incomplete until every child is published.
  public func beginGitCommit(repo: Int, prepared: GitPreparedMetadata, generation: Int, now: Int, preparationPolicy: GitPreparationPolicy? = nil) throws -> Int? {
    try checkGitCancellation()
    let policy = try preparationPolicy ?? gitPreparationPolicy()
    let small = try prepared.fields.map { try $0.smallText() ?? "" }
    let commit = GitCommitRecord(hash: prepared.hash, authorTime: prepared.authorTime, commitTime: prepared.commitTime,
      author: "", email: "", message: "")
    let abandoned: Int? = try gitLocked {
      var id: Int?
      try connection.namedRows("SELECT id FROM git_commits WHERE repo_id=? AND hash=? AND complete!=1", [.integer(repo), .key(prepared.hash)]) { id = try $0.int("id") }
      return id
    }
    if let abandoned { try abandonGitCommit(abandoned); try checkGitCancellation() }
    guard let id = try publishGitCommit(repo: repo, commit: commit, generation: generation, policy: policy,
      author: small[0], email: small[1], message: small[2], now: now) else { return nil }
    var transferred = false
    defer { if !transferred { try? abandonGitCommit(id) } }
    do { for (field, text) in prepared.fields.enumerated() {
      if text.byteCount <= 65536 { continue }
      var ordinal = 0
      try text.forEachChunk { bytes in
        let result = try publishGit(.commitUnit(id), now: now) {
          try connection.run("INSERT INTO git_commit_text(commit_id,field,ordinal,payload) VALUES(?,?,?,?)",
            [.integer(id), .integer(field), .integer(ordinal), .maskedBlob(bytes)])
        }
        if case .refused(.privacy) = result { throw GitChunkInterruption.forgotten }
        guard case .admitted = result else { throw StorageError("Git preparation interrupted") }
        ordinal += 1; try gitUnit(["author", "email", "message"][field])
        // The recorder retries with a zero busy timeout. Leave an admission interval
        // between chunks instead of reacquiring the writer continuously for a large field.
        Thread.sleep(forTimeInterval: 0.001)
      }
    } } catch GitChunkInterruption.forgotten { }
    transferred = true
    return id
  }
  public func appendGitFile(_ file: GitChangedFile, commit: Int, now: Int) throws {
    try withGitCommitWork(commit) {
      let old = try GitMaskedText.prepare(file.oldPath, in: FileManager.default.temporaryDirectory)
      let path = try GitMaskedText.prepare(file.path, in: FileManager.default.temporaryDirectory)
      try appendGitFile(GitPreparedChangedFile(oldPath: old, path: path, added: file.added, deleted: file.deleted), commit: commit, now: now)
    }
  }
  public func appendGitFile(_ file: GitPreparedChangedFile, commit: Int, now: Int) throws {
    try withGitCommitWork(commit) {
      try checkGitCancellation()
      let old = try file.oldPath?.smallText() ?? ""
      let path = try file.path.smallText() ?? ""
      let id = try publishGit(.commitUnit(commit), now: now) {
        try connection.run("INSERT INTO git_files(commit_id,old_path,path,added,deleted) VALUES(?,?,?,?,?)",
          [.integer(commit), .maskedText(old), .maskedText(path), file.added.map(SQLValue.integer) ?? .null,
            file.deleted.map(SQLValue.integer) ?? .null])
        return Int(sqlite3_last_insert_rowid(connection.handle))
      }.value
      guard let id else { return }
      if let old = file.oldPath { try appendGitValue(old, kind: 1, owner: id, field: 0, commit: commit, now: now) }
      try appendGitValue(file.path, kind: 1, owner: id, field: 1, commit: commit, now: now)
    }
  }
  private func appendGitValue(_ text: GitMaskedText, kind: Int, owner: Int, field: Int, commit: Int, now: Int) throws {
    guard text.byteCount > 65536 else { return }
    var ordinal = 0
    do { try text.forEachChunk { bytes in
      let result = try publishGit(.commitUnit(commit), now: now) {
        try connection.run("INSERT INTO git_value_text(kind,owner_id,field,ordinal,payload) VALUES(?,?,?,?,?)",
          [.integer(kind), .integer(owner), .integer(field), .integer(ordinal), .maskedBlob(bytes)])
      }
      if case .refused(.privacy) = result { throw GitChunkInterruption.forgotten }
      guard case .admitted = result else { throw StorageError("Git value preparation interrupted") }
      ordinal += 1; try gitUnit(kind == 1 ? "file" : "commit-ref"); Thread.sleep(forTimeInterval: 0.001)
    } } catch GitChunkInterruption.forgotten { }
  }
  func gitCommitWasForgotten(_ id: Int) throws -> Bool {
    guard let read = gitCommitReads[id] else { return false }
    return try connection.integer("SELECT count(*) FROM git_tombstones WHERE hash=?", [.key(read.hash)]) > 0
  }
  public func appendGitCommitRef(_ ref: GitMaskedText, identity: String, commit: Int, now: Int) throws {
    try withGitCommitWork(commit) {
      try checkGitCancellation()
      let name = try ref.smallText() ?? ""
      let result = try publishGit(.commitUnit(commit), now: now) { () throws -> Int? in
        try connection.run("INSERT OR IGNORE INTO git_commit_refs(commit_id,identity,name) VALUES(?,?,?)",
          [.integer(commit), .key(identity), .maskedText(name)])
        if sqlite3_changes(connection.handle) == 0 { return nil }
        return Int(sqlite3_last_insert_rowid(connection.handle))
      }
      if let id = result.value ?? nil { try appendGitValue(ref, kind: 2, owner: id, field: 0, commit: commit, now: now) }
    }
  }
  public func appendGitCommitRef(_ ref: String, commit: Int, now: Int) throws {
    try withGitCommitWork(commit) {
      try appendGitCommitRef(GitMaskedText.prepare(ref, in: FileManager.default.temporaryDirectory),
        identity: Self.gitDigest(ref), commit: commit, now: now)
    }
  }
  /// An interrupted stream cannot certify its children, even if recording has resumed.
  @discardableResult public func finishGitCommit(_ id: Int, now: Int) throws -> GitCommitFinish {
    try checkGitCancellation()
    try beforeGitCommitCompletion?()
    defer { try? gitLocked { _ = gitCommitReads.removeValue(forKey: id) } }
    let publication = try publishGit(.commitCompletion(id), now: now) {
      try connection.run("UPDATE git_commits SET complete=1 WHERE id=? AND complete=0", [.integer(id)])
      return sqlite3_changes(connection.handle) == 1
    }
    switch publication {
    case .admitted(true): return .complete
    case .admitted(false):
      try gitLocked { if let read = gitCommitReads[id] { interruptGitRead(read.repo) } }
      return .retry
    case .refused(let reason):
      try discardGitCommitContent(id)
      return reason == .privacy || reason == .expired ? .privacyRefused : .retry
    }
  }
  public func abandonGitCommit(_ id: Int) throws {
    try gitLocked {
      if let read = gitCommitReads.removeValue(forKey: id) { interruptGitRead(read.repo) }
      try connection.run("UPDATE git_commits SET complete=-1 WHERE id=? AND complete=0", [.integer(id)])
    }
    try discardGitCommitContent(id)
  }
  func cleanGitOrphans() throws {
    try connection.run("DELETE FROM git_repositories WHERE NOT EXISTS(SELECT 1 FROM git_working_folders WHERE repo_id=git_repositories.id)")
  }
  func purgeOwnGitSource(_ position: LogPosition, tool: AgentLogTool, sourceKey: AgentLogPhysicalSource) throws {
    try connection.run("DELETE FROM git_working_folders WHERE tool=? AND device=? AND inode=? AND source=?",
      [.key(tool.rawValue), .integer(position.device), .integer(position.inode), .key(sourceKey)])
    try cleanGitOrphans()
  }
  func cleanGitRetention(oldest: Int) throws {
    try connection.run("DELETE FROM git_commits WHERE ts<? OR author_ts<?", [.integer(oldest), .integer(oldest)])
    try connection.run("DELETE FROM git_refs WHERE ts<?", [.integer(oldest)])
    try connection.run("DELETE FROM git_working_folders WHERE last_seen<?", [.integer(oldest)])
    try cleanGitOrphans()
  }
  /// Byte counts are UTF-8 string payloads, excluding SQLite pages and indexes.
  public func gitStatus() throws -> String {
    try gitLocked {
      guard try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='git_repositories'") > 0 else { return "git_repos=0" }
      var fields: [String] = []
      let provenance = try connection.integer("SELECT count(*) FROM pragma_table_info('git_working_folders') WHERE name='discovery'") > 0
      for table in ["git_repositories", "git_working_folders", "git_refs", "git_commits", "git_commit_refs", "git_files", "git_commit_text", "git_value_text", "git_tombstones", "git_discovery_tombstones"] {
        let columns: [String: String] = ["git_repositories": "length(CAST(common_dir AS BLOB))+length(identity)",
          "git_working_folders": "length(CAST(source||session||folder||top_level||branch||head||status||tool AS BLOB))+length(identity)+length(discovery)",
          "git_refs": "length(CAST(name AS BLOB))+length(identity)+length(tip)",
          "git_commits": "length(CAST(author||email||message AS BLOB))+length(hash)",
          "git_commit_refs": "length(CAST(name AS BLOB))+length(identity)", "git_files": "length(CAST(old_path||path AS BLOB))", "git_commit_text": "length(payload)", "git_value_text": "length(payload)", "git_tombstones": "length(hash)", "git_discovery_tombstones": "length(hash)"]
        guard try connection.integer("SELECT count(*) FROM sqlite_master WHERE name=?", [.key(table)]) > 0 else { continue }
        let payload = table == "git_working_folders" && !provenance
          ? "length(CAST(source||session||folder||top_level||branch||head||status AS BLOB))+length(identity)" : columns[table]!
        fields.append("\(table)=\(try connection.integer("SELECT count(*) FROM \(table)"))")
        fields.append("\(table)_bytes=\(try connection.integer("SELECT COALESCE(sum(\(payload)),0) FROM \(table)"))")
      }
      let reopenColumn = try connection.integer("SELECT count(*) FROM pragma_table_info('git_repositories') WHERE name='reopen_blocked'") > 0
      let blocked = reopenColumn ? try connection.integer("SELECT count(*) FROM git_repositories WHERE reopen_blocked=1") : 0
      fields.append("git_masked_reopen_blocked=\(blocked)")
      fields.append("git_missing_folders=\(try connection.integer("SELECT count(*) FROM git_working_folders WHERE status='missing'"))")
      fields.append("git_unversioned_folders=\(try connection.integer("SELECT count(*) FROM git_working_folders WHERE status='unversioned'"))")
      fields.append("git_last_read=\(try connection.integer("SELECT COALESCE(max(last_read),0) FROM git_repositories"))")
      fields.append("git_failures=\(try connection.integer("SELECT (SELECT COALESCE(sum(failures),0) FROM git_repositories)+(SELECT COALESCE(sum(failures),0) FROM git_working_folders)"))")
      return fields.joined(separator: " ")
    }
  }
}

extension ActivityStorage {
  func gitSourceRevision() throws -> Int? {
    guard try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='git_source_revision'") > 0 else { return nil }
    return try connection.integer("SELECT value FROM git_source_revision WHERE id=1")
  }
  func gitDeletionRevision() throws -> Int? {
    guard try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='git_privacy_revision'") > 0 else { return nil }
    return try connection.integer("SELECT value FROM git_privacy_revision WHERE id=1")
  }
  /// All content hashing and checkpoint decoding uses a private WAL snapshot, never the
  /// maintenance connection or the deletion writer. Only a revision receipt crosses over.
  func fingerprintGitDeletion(_ range: TimeRange) throws -> GitDeletionFingerprint {
    try prepareGitDeletion(range)
    var digest = SHA256(), counts: [String: Int] = [:]
    for (table, selection) in gitDeletionSelections {
      digest.update(data: Data(table.utf8)); var count = 0
      try connection.rows("SELECT * FROM \(table) WHERE \(selection) ORDER BY id", [.integer(range.start), .integer(range.end)]) { row in
        autoreleasepool {
          count += 1
          for column in 0..<sqlite3_column_count(row) {
            let type = sqlite3_column_type(row, column), size = sqlite3_column_bytes(row, column)
            digest.update(data: Data("|\(type):\(size):".utf8))
            if let bytes = sqlite3_column_blob(row, column), size > 0 { digest.update(data: Data(bytes: bytes, count: Int(size))) }
          }
          digest.update(data: Data(";".utf8))
        }
      }
      counts[table] = count
    }
    let checkpoints = try digestGitCheckpoints(into: &digest)
    if checkpoints > 0 { counts["git_checkpoint_discoveries"] = checkpoints }
    return GitDeletionFingerprint(digest: Data(digest.finalize()), counts: counts, revision: try gitDeletionRevision())
  }
  func copyGitDeletionSelections(from snapshot: ActivityStorage) throws {
    for name in ["repos", "commits", "folders", "refs", "hashes", "checkpoints", "discoveries"] {
      let table = "git_deletion_" + name
      guard try snapshot.connection.integer("SELECT count(*) FROM sqlite_temp_master WHERE name=?", [.key(table)]) > 0 else { continue }
      let hash = name == "hashes" || name == "discoveries"
      let column = hash ? "hash TEXT PRIMARY KEY" : "id INTEGER PRIMARY KEY"
      try gitLocked { try connection.run("CREATE TEMP TABLE IF NOT EXISTS \(table)(\(column))") }
      while try gitLocked({ () throws -> Bool in
        try connection.run("DELETE FROM \(table) WHERE rowid IN (SELECT rowid FROM \(table) LIMIT 256)")
        return sqlite3_changes(connection.handle) > 0
      }) { Thread.sleep(forTimeInterval: 0.001) }
      try snapshot.connection.rows("SELECT * FROM \(table)") { row in
        let value: SQLValue = hash ? .key(SQLiteConnection.text(row, 0)) : .integer(SQLiteConnection.int(row, 0))
        try gitLocked { try connection.run("INSERT INTO \(table) VALUES(?)", [value]) }
      }
    }
    guard try snapshot.connection.integer("SELECT count(*) FROM sqlite_temp_master WHERE name='git_deletion_discovery_sources'") > 0 else { return }
    try gitLocked {
      try connection.run("CREATE TEMP TABLE IF NOT EXISTS git_deletion_discovery_sources(hash TEXT NOT NULL,folder_id INTEGER,intrinsic INTEGER NOT NULL)")
      try connection.run("DELETE FROM git_deletion_discovery_sources")
    }
    try snapshot.connection.rows("SELECT hash,folder_id,intrinsic FROM git_deletion_discovery_sources") { row in
      let folder: SQLValue = sqlite3_column_type(row, 1) == SQLITE_NULL ? .null : .integer(SQLiteConnection.int(row, 1))
      try gitLocked { try connection.run("INSERT INTO git_deletion_discovery_sources VALUES(?,?,?)",
        [.key(SQLiteConnection.text(row, 0)), folder, .integer(SQLiteConnection.int(row, 2))]) }
    }
  }
  func prepareGitDeletion(_ range: TimeRange) throws {
    guard try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='git_repositories'") > 0 else { return }
    for table in ["repos", "commits", "folders", "refs"] {
      try connection.run("CREATE TEMP TABLE IF NOT EXISTS git_deletion_\(table)(id INTEGER PRIMARY KEY)")
      try connection.run("DELETE FROM git_deletion_\(table)")
    }
    try connection.run("CREATE TEMP TABLE IF NOT EXISTS git_deletion_hashes(hash TEXT PRIMARY KEY)")
    try connection.run("DELETE FROM git_deletion_hashes")
    try connection.run("CREATE TEMP TABLE IF NOT EXISTS git_deletion_checkpoints(id INTEGER PRIMARY KEY)")
    try connection.run("DELETE FROM git_deletion_checkpoints")
    try connection.run("CREATE TEMP TABLE IF NOT EXISTS git_deletion_discoveries(hash TEXT PRIMARY KEY)")
    try connection.run("DELETE FROM git_deletion_discoveries")
    // Why each discovery was selected: in the range by its own time, or through a folder.
    // Narrowing keeps only discoveries whose folder is still erased or that are in range.
    try connection.run("CREATE TEMP TABLE IF NOT EXISTS git_deletion_discovery_sources(hash TEXT NOT NULL,folder_id INTEGER,intrinsic INTEGER NOT NULL)")
    try connection.run("DELETE FROM git_deletion_discovery_sources")
    let values: [SQLValue] = [.integer(range.start), .integer(range.end)]
    try connection.run("""
      INSERT INTO git_deletion_repos SELECT repo_id FROM git_working_folders WHERE repo_id IS NOT NULL
      GROUP BY repo_id HAVING MIN(last_seen)>=? AND MAX(ts)<?
      """, values)
    try connection.run("INSERT INTO git_deletion_folders SELECT id FROM git_working_folders WHERE (last_seen>=? AND ts<?) OR repo_id IN git_deletion_repos", values)
    try connection.run("""
      INSERT INTO git_deletion_commits SELECT id FROM git_commits
      WHERE (ts>=? AND ts<?) OR (author_ts>=? AND author_ts<?) OR repo_id IN git_deletion_repos
      """, values + values)
    try connection.run("INSERT INTO git_deletion_refs SELECT id FROM git_refs WHERE (ts>=? AND ts<?) OR repo_id IN git_deletion_repos", values)
    try connection.run("INSERT INTO git_deletion_hashes SELECT hash FROM git_commits WHERE id IN git_deletion_commits")
    if try connection.integer("SELECT count(*) FROM pragma_table_info('git_working_folders') WHERE name='discovery'") > 0 {
      try connection.run("INSERT OR IGNORE INTO git_deletion_discoveries SELECT discovery FROM git_working_folders WHERE id IN git_deletion_folders AND discovery!=''")
      try connection.run("INSERT INTO git_deletion_discovery_sources SELECT discovery,id,ts>=? AND ts<? FROM git_working_folders WHERE id IN git_deletion_folders AND discovery!=''", values)
    }
    // Older read-only previews may predate the agent-event tables.
    if try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='agent_log_events'") > 0 {
      // Retained old events outside the forgotten interval must not replay a deleted relationship.
      let attributed = try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='agent_log_event_sessions'") > 0
      let session = attributed ? "COALESCE(s.session_id,e.session_id,'')" : "COALESCE(e.session_id,'')"
      let join = attributed ? "LEFT JOIN agent_log_event_sessions s ON s.event_id=e.id" : ""
      try connection.namedRows("""
        SELECT e.*,\(session) AS git_session,f.id AS git_folder FROM agent_log_events e \(join)
          JOIN git_working_folders f ON f.id IN git_deletion_folders
            AND f.device=e.device AND f.inode=e.inode AND f.source=e.source
            AND f.session=\(session) AND f.folder=e.project
        """) { row in
        let folder = GitWorkingFolder(folder: try row.text("project"), session: try row.text("git_session"),
          source: try row.text("source"), device: try row.int("device"), inode: try row.int("inode"), time: try row.int("ts"),
          tool: AgentLogTool(rawValue: try row.text("tool")), sourceIdentity: AgentLogIdentityCodec.physical(try row.text("source")))
        let discovery = Self.gitDiscoveryKey(folder)
        try connection.run("INSERT OR IGNORE INTO git_deletion_discoveries VALUES(?)", [.key(discovery)])
        try connection.run("INSERT INTO git_deletion_discovery_sources VALUES(?,?,?)",
          [.key(discovery), .integer(try row.int("git_folder")), .integer(folder.time >= range.start && folder.time < range.end ? 1 : 0)])
      }
    }
    try connection.namedRows("SELECT rowid AS id,* FROM log_positions WHERE json_valid(state)") { row in
      let state = try AgentLogState.decode(row.text("state"))
      guard let time = state.cwdObservedAt, !state.project.isEmpty else { return }
      let folder = GitWorkingFolder(folder: state.project, session: (state.cwdSession ?? state.session)?.storedKey ?? "", source: try row.text("path"),
        device: try row.int("device"), inode: try row.int("inode"), time: time, tool: state.tool.flatMap(AgentLogTool.init(rawValue:)), sourceIdentity: AgentLogIdentityCodec.physical(try row.text("path")))
      var selected: [Int] = []
      try connection.namedRows("SELECT id FROM git_working_folders WHERE id IN git_deletion_folders AND device=? AND inode=? AND source=? AND session=? AND folder=?",
        [.integer(folder.device), .integer(folder.inode), .key(folder.physicalSource.storedKey), .key(AgentLogIdentityCodec.session(folder.session).storedKey), .text(folder.folder)]) {
        selected.append(try $0.int("id"))
      }
      let intrinsic = time >= range.start && time < range.end
      if intrinsic || !selected.isEmpty {
        let discovery = Self.gitDiscoveryKey(folder)
        try connection.run("INSERT INTO git_deletion_checkpoints VALUES(?)", [.integer(try row.int("id"))])
        try connection.run("INSERT OR IGNORE INTO git_deletion_discoveries VALUES(?)", [.key(discovery)])
        if intrinsic { try connection.run("INSERT INTO git_deletion_discovery_sources VALUES(?,NULL,1)", [.key(discovery)]) }
        for id in selected { try connection.run("INSERT INTO git_deletion_discovery_sources VALUES(?,?,0)", [.key(discovery), .integer(id)]) }
      }
    }
  }
  func digestGitCheckpoints(into digest: inout SHA256) throws -> Int {
    guard try connection.integer("SELECT count(*) FROM sqlite_temp_master WHERE name='git_deletion_checkpoints'") > 0 else { return 0 }
    var count = 0
    try connection.namedRows("SELECT rowid AS id,* FROM log_positions WHERE rowid IN git_deletion_checkpoints ORDER BY rowid") { row in
      count += 1
      for value in [String(try row.int("id")), try row.text("path"), String(try row.int("device")), String(try row.int("inode")), try row.text("state")] {
        digest.update(data: Data("|git-checkpoint:\(value.utf8.count):\(value)".utf8))
      }
    }
    try connection.namedRows("SELECT hash FROM git_deletion_discoveries ORDER BY hash") { row in
      digest.update(data: Data(("|git-discovery:" + (try row.text("hash"))).utf8))
    }
    return count
  }
  var gitDeletionSelections: [(String, String)] {
    guard (try? connection.integer("SELECT count(*) FROM sqlite_master WHERE name='git_repositories'")) == 1 else { return [] }
    let text = (try? connection.integer("SELECT count(*) FROM sqlite_master WHERE name='git_commit_text'")) == 1
      ? [("git_commit_text", "commit_id IN git_deletion_commits AND ?<?")] : []
    let values = (try? connection.integer("SELECT count(*) FROM sqlite_master WHERE name='git_value_text'")) == 1
      ? [("git_value_text", "(kind=1 AND owner_id IN (SELECT id FROM git_files WHERE commit_id IN git_deletion_commits) OR kind=2 AND owner_id IN (SELECT id FROM git_commit_refs WHERE commit_id IN git_deletion_commits) OR kind=3 AND owner_id IN git_deletion_refs OR kind=4 AND owner_id IN git_deletion_folders) AND ?<?")] : []
    return values + text + [
      ("git_files", "commit_id IN git_deletion_commits AND ?<?"),
      ("git_commit_refs", "commit_id IN git_deletion_commits AND ?<?"),
      ("git_commits", "id IN git_deletion_commits AND ?<?"),
      ("git_refs", "id IN git_deletion_refs AND ?<?"),
      ("git_working_folders", "id IN git_deletion_folders AND ?<?"),
      ("git_repositories", "id IN git_deletion_repos AND ?<?"),
    ]
  }
  /// Collection batches commit before Git erasure, so the recorder may publish in
  /// those gaps. A repository that gained a folder, commit or ref since the preview,
  /// or whose folders no longer all lie in the range, is not erased whole: only its
  /// rows that are in the range by themselves go, and the cascade stays previewed.
  func narrowGitDeletion(_ range: TimeRange) throws {
    guard try connection.integer("SELECT count(*) FROM sqlite_temp_master WHERE name='git_deletion_repos'") > 0 else { return }
    let values: [SQLValue] = [.integer(range.start), .integer(range.end)]
    try connection.run("""
      DELETE FROM git_deletion_repos WHERE id NOT IN (SELECT repo_id FROM git_working_folders WHERE repo_id IS NOT NULL
          GROUP BY repo_id HAVING MIN(last_seen)>=? AND MAX(ts)<?)
        OR EXISTS(SELECT 1 FROM git_working_folders f WHERE f.repo_id=git_deletion_repos.id AND f.id NOT IN git_deletion_folders)
        OR EXISTS(SELECT 1 FROM git_commits c WHERE c.repo_id=git_deletion_repos.id AND c.id NOT IN git_deletion_commits)
        OR EXISTS(SELECT 1 FROM git_refs r WHERE r.repo_id=git_deletion_repos.id AND r.id NOT IN git_deletion_refs)
      """, values)
    try connection.run("""
      DELETE FROM git_deletion_folders WHERE id NOT IN (SELECT id FROM git_working_folders
        WHERE (last_seen>=? AND ts<?) OR repo_id IN git_deletion_repos)
      """, values)
    try connection.run("""
      DELETE FROM git_deletion_commits WHERE id NOT IN (SELECT id FROM git_commits
        WHERE (ts>=? AND ts<?) OR (author_ts>=? AND author_ts<?) OR repo_id IN git_deletion_repos)
      """, values + values)
    try connection.run("DELETE FROM git_deletion_refs WHERE id NOT IN (SELECT id FROM git_refs WHERE (ts>=? AND ts<?) OR repo_id IN git_deletion_repos)", values)
    try narrowGitDeletionMarks()
  }
  /// The first batch tombstoned the whole previewed selection. Tombstones this forget
  /// added for a row that narrowing left in place, and that is not in the range by
  /// itself, are taken back; a commit or folder that stays can still be collected.
  private func narrowGitDeletionMarks() throws {
    guard try connection.integer("SELECT count(*) FROM sqlite_temp_master WHERE name IN ('git_deletion_new_hashes','git_deletion_new_discoveries','git_deletion_discovery_sources')") == 3 else { return }
    try connection.run("""
      DELETE FROM git_deletion_hashes WHERE hash NOT IN (SELECT hash FROM git_commits WHERE id IN git_deletion_commits)
        AND hash IN (SELECT hash FROM git_commits)
      """)
    try connection.run("DELETE FROM git_tombstones WHERE hash IN git_deletion_new_hashes AND hash NOT IN git_deletion_hashes")
    try connection.run("""
      DELETE FROM git_deletion_discoveries WHERE hash NOT IN (SELECT hash FROM git_deletion_discovery_sources
        WHERE intrinsic=1 OR folder_id IN git_deletion_folders)
      """)
    try connection.run("DELETE FROM git_discovery_tombstones WHERE hash IN git_deletion_new_discoveries AND hash NOT IN git_deletion_discoveries")
  }
  func markGitDeletion() throws {
    guard try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='git_tombstones'") > 0 else { return }
    // Only tombstones this forget adds can be taken back by narrowing.
    try connection.run("CREATE TEMP TABLE IF NOT EXISTS git_deletion_new_hashes(hash TEXT PRIMARY KEY)")
    try connection.run("DELETE FROM git_deletion_new_hashes")
    try connection.run("INSERT INTO git_deletion_new_hashes SELECT hash FROM git_deletion_hashes WHERE hash NOT IN git_tombstones")
    try connection.run("CREATE TEMP TABLE IF NOT EXISTS git_deletion_new_discoveries(hash TEXT PRIMARY KEY)")
    try connection.run("DELETE FROM git_deletion_new_discoveries")
    try connection.run("INSERT INTO git_deletion_new_discoveries SELECT hash FROM git_deletion_discoveries WHERE hash NOT IN git_discovery_tombstones")
    try connection.run("INSERT OR IGNORE INTO git_tombstones SELECT hash FROM git_deletion_hashes")
    try connection.run("INSERT OR IGNORE INTO git_discovery_tombstones SELECT hash FROM git_deletion_discoveries")
  }
  func verifyGitDeletion() throws {
    guard try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='git_tombstones'") > 0 else { return }
    guard try connection.integer("SELECT count(*) FROM git_deletion_hashes WHERE hash NOT IN git_tombstones") == 0,
      try connection.integer("SELECT count(*) FROM git_deletion_discoveries WHERE hash NOT IN git_discovery_tombstones") == 0 else {
      throw StorageError("Git deletion marker missing")
    }
  }
}
