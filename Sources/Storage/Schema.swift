import Foundation

extension SQLiteConnection {
  static let schemaVersion = 16
  static let applicationID = 0x4150_5342

  /// Later schema changes go in this function, before the version is advanced.
  func validateSchemaOrigin() throws -> Int {
    let version = try integer("PRAGMA user_version")
    guard version <= Self.schemaVersion else { throw StorageError("Database version is newer than this storage") }
    guard [0, 9, 14, 15, Self.schemaVersion].contains(version) else {
      throw StorageError("Unsupported database schema \(version): supported origins are a fresh database and main schemas 9, 14 and 15 (current \(Self.schemaVersion))")
    }
    let application = try integer("PRAGMA application_id")
    let tableCount = try integer("SELECT count(*) FROM sqlite_master WHERE type='table'")
    guard (version > 0 && application == Self.applicationID) || (version == 0 && application == 0 && tableCount == 0)
    else { throw StorageError("Use conversion to import an old database into a separate new database") }
    if version == 14 || version == 15 {
      guard try integer("SELECT count(*) FROM sqlite_master WHERE name='collection_metadata'") == 1,
        try integer("SELECT count(*) FROM sqlite_master WHERE name='git_repositories'") == 0 else {
        throw StorageError("Unsupported undeployed Git schema")
      }
    }
    return version
  }
  func createSchema() throws {
    let version = try validateSchemaOrigin()
    try run("PRAGMA secure_delete=ON")
    try run("PRAGMA journal_mode=WAL")
    if version == Self.schemaVersion {
      // Upgrade legacy probe metadata once; ordinary opens must remain read-only.
      if try integer("""
        SELECT count(*) FROM (SELECT 1 FROM sqlite_master WHERE type='trigger' AND name='ax_probe_review_no_enable'
          AND instr(sql,'general.axProbe.reviewLease')=0
        UNION ALL SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM pragma_table_info('ax_probe_pid') WHERE name='failure_policy'))
        """) > 0 { try transaction { try createAXProbeSchema() } }
      if try integer("SELECT count(*) FROM sqlite_master WHERE name IN ('git_commit_text','git_text_cleanup','git_value_text','git_files_text_cleanup','git_commit_refs_text_cleanup','git_refs_text_cleanup','git_working_folders_text_cleanup','git_ref_frontier','git_ref_repo_id','git_commit_completion','git_privacy_revision','git_source_revision','log_positions_git_recovery','git_ref_pending_insert','git_ref_pending_delete','git_ref_pending_update','git_abandoned_commits','git_abandoned_folders','git_incomplete_commits','git_incomplete_folders','git_file_commit','git_commit_ref_owner','git_retention_progress','git_backfill_progress','git_backfill_progress_event','git_backfill_progress_clamp')") != 26
        || integer("SELECT count(*) FROM pragma_table_info('git_repositories') WHERE name='frontier'") != 1
        || integer("SELECT count(*) FROM pragma_table_info('git_repositories') WHERE name='pending_frontier'") != 1
        || integer("SELECT count(*) FROM pragma_table_info('git_repositories') WHERE name='pending_ref_count'") != 1
        || integer("SELECT count(*) FROM pragma_table_info('git_refs') WHERE name='frontier'") != 1
        || integer("SELECT count(*) FROM pragma_table_info('git_working_folders') WHERE name='complete'") != 1
        || integer("SELECT count(*) FROM pragma_table_info('git_working_folders') WHERE name='ownership_authority'") != 1
        || integer("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'git_revision_%'") != 33
        || integer("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'git_source_revision_%'") != 21 {
        try transaction { try createGitTextSchema() }
      }
      collectionAccountingEnabled = true
      return
    }
    if version == 15 {
      try transaction {
        try createGitSchema()
        try run("PRAGMA user_version=\(Self.schemaVersion)")
      }
      collectionAccountingEnabled = true
      return
    }
    if version == 14 {
      // Main 14 already installed collection capabilities atomically. Agent-log adoption
      // adds receipts and tables only, without revisiting historical collection rows.
      try transaction {
        try createAgentLogSchema()
        try createAgentLogBaselineSchema()
        try legacyLogAdapter.createSchema()
        try legacyLogAdapter.adoptNativeIdentities()
        try createGitSchema()
        try run("PRAGMA user_version=\(Self.schemaVersion)")
      }
      collectionAccountingEnabled = true
      return
    }
    try transaction(collectionMaintenance: true, collectionFullBaseline: true) {
      for sql in [
        """
        CREATE TABLE IF NOT EXISTS samples (
          id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, bundle_id TEXT NOT NULL, app TEXT NOT NULL,
          window TEXT NOT NULL, document_key TEXT NOT NULL,
          keys INTEGER NOT NULL CHECK(keys>=0), clicks INTEGER NOT NULL CHECK(clicks>=0),
          scrolls INTEGER NOT NULL CHECK(scrolls>=0), moved INTEGER NOT NULL CHECK(moved IN (0,1)),
          synthetic INTEGER NOT NULL CHECK(synthetic>=0), keeping_awake INTEGER NOT NULL CHECK(keeping_awake IN (0,1)),
          excluded INTEGER NOT NULL CHECK(excluded IN (0,1)))
        """,
        "CREATE INDEX IF NOT EXISTS samples_time ON samples(ts)",
        """
        CREATE TABLE IF NOT EXISTS intervals (
          id INTEGER PRIMARY KEY, start_ts INTEGER NOT NULL, end_ts INTEGER NOT NULL,
          name TEXT NOT NULL, description TEXT NOT NULL, kind TEXT CHECK(kind IN ('work','personal','distraction')),
          project TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('named','private')),
          CHECK(end_ts>start_ts AND start_ts%60=0 AND end_ts%60=0),
          CHECK((state='named' AND kind IS NOT NULL) OR (state!='named' AND kind IS NULL)))
        """,
        "CREATE INDEX IF NOT EXISTS intervals_time ON intervals(start_ts,end_ts)",
        """
        CREATE TRIGGER IF NOT EXISTS intervals_no_overlap BEFORE INSERT ON intervals
        WHEN EXISTS(SELECT 1 FROM intervals WHERE start_ts<NEW.end_ts AND end_ts>NEW.start_ts)
        BEGIN SELECT RAISE(ABORT,'One minute belongs to at most one interval'); END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS intervals_no_rewrite BEFORE UPDATE ON intervals
        BEGIN SELECT RAISE(ABORT,'Earlier intervals cannot be rewritten'); END
        """,
        """
        CREATE TABLE IF NOT EXISTS evidence (
          id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('screen','prompt')),
          source TEXT NOT NULL, source_id TEXT, document_key TEXT NOT NULL, project TEXT NOT NULL, text TEXT NOT NULL)
        """,
        "CREATE INDEX IF NOT EXISTS evidence_time_kind ON evidence(kind,ts)",
        """
        CREATE INDEX IF NOT EXISTS evidence_prompt_id ON evidence(source_id)
        WHERE kind='prompt' AND source_id IS NOT NULL
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS evidence_source_identity ON evidence(source,source_id)
        WHERE source_id IS NOT NULL
        """,
        """
        CREATE TABLE IF NOT EXISTS log_recording_history (
          id INTEGER PRIMARY KEY, since INTEGER NOT NULL, enabled INTEGER NOT NULL,
          paused_until INTEGER)
        """,
        "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        """
        CREATE TABLE IF NOT EXISTS log_positions (
          path TEXT PRIMARY KEY, device INTEGER NOT NULL, inode INTEGER NOT NULL,
          offset INTEGER NOT NULL CHECK(offset>=0), state TEXT NOT NULL, seen_ts INTEGER NOT NULL)
        """,
        """
        CREATE TABLE IF NOT EXISTS model_calls (
          id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, start_ts INTEGER NOT NULL, end_ts INTEGER NOT NULL,
          model TEXT NOT NULL, input_tokens INTEGER NOT NULL CHECK(input_tokens>=0),
          cached_tokens INTEGER NOT NULL CHECK(cached_tokens>=0),
          output_tokens INTEGER NOT NULL CHECK(output_tokens>=0),
          succeeded INTEGER NOT NULL CHECK(succeeded IN (0,1)), CHECK(end_ts>start_ts))
        """,
        "CREATE TABLE IF NOT EXISTS forgotten_ranges (start_ts INTEGER NOT NULL,end_ts INTEGER NOT NULL)",
        """
        CREATE TABLE IF NOT EXISTS forgotten_sources (
          source TEXT NOT NULL,source_id TEXT NOT NULL,PRIMARY KEY(source,source_id))
        """,
        """
        CREATE INDEX IF NOT EXISTS forgotten_source_id ON forgotten_sources(source_id)
        """,
        """
        CREATE TABLE IF NOT EXISTS conversion_progress (
          source TEXT NOT NULL, layer TEXT NOT NULL, last_row INTEGER NOT NULL, PRIMARY KEY(source,layer))
        """,
      ] { try run(sql) }
      try createCollectionSchema()
      // Identity is a fact of the new record. Historical rows stay NULL, with
      // no attempt to recover identity from another record or a masked label.
      for table in ["samples", "evidence", "input_batches", "collection_metadata"] {
        if try integer("SELECT count(*) FROM pragma_table_info('\(table)') WHERE name='application_identity'") == 0 {
          try run("ALTER TABLE \(table) ADD COLUMN application_identity TEXT")
        }
      }
      if version < 11 { try backfillCollectionNovelty() }
      // Replace only the accounting definitions affected by additive columns.
      // Their historical numeric rows are retained without recomputation.
      for table in ["evidence", "input_batches", "collection_metadata"] {
        try run("DROP TRIGGER IF EXISTS ingestion_\(table)")
      }
      try createCollectionAccounting()
      try createAXProbeSchema()
      try createAgentLogSchema()
      try createAgentLogBaselineSchema()
      try createGitSchema()
      try legacyLogAdapter.createSchema()
      if version > 0 && version < 15 { try legacyLogAdapter.adoptNativeIdentities() }
      var hasTableFacts = false
      try rows("PRAGMA table_info(model_calls)") { row in
        if Self.optionalText(row, 1) == "table_facts" { hasTableFacts = true }
      }
      if !hasTableFacts { try run("ALTER TABLE model_calls ADD COLUMN table_facts TEXT") }
      var callColumns = Set<String>()
      try rows("PRAGMA table_info(model_calls)") { callColumns.insert(Self.text($0, 1)) }
      if !callColumns.contains("pending") {
        try run("ALTER TABLE model_calls ADD COLUMN pending INTEGER NOT NULL DEFAULT 0 CHECK(pending IN (0,1))")
      }
      if !callColumns.contains("attempt_id") { try run("ALTER TABLE model_calls ADD COLUMN attempt_id TEXT") }
      try run("CREATE UNIQUE INDEX IF NOT EXISTS model_call_attempt ON model_calls(attempt_id)")
      // Existing pause/off settings seed the history at adoption; later settings writes add timed transitions.
      try run("""
        INSERT INTO log_recording_history(since,enabled,paused_until)
        SELECT -9223372036854775808,
          COALESCE((SELECT CAST(value AS INTEGER) FROM settings WHERE key='recording'),1),
          (SELECT CAST(value AS INTEGER) FROM settings WHERE key='pause')
        WHERE NOT EXISTS(SELECT 1 FROM log_recording_history)
        """)
      try run("PRAGMA application_id=\(Self.applicationID)")
      try run("PRAGMA user_version=\(Self.schemaVersion)")
    }
    collectionAccountingEnabled = true
  }
}
