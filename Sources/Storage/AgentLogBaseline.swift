import Core
import Foundation

extension SQLiteConnection {
  func createAgentLogBaselineSchema() throws {
    try run("CREATE TABLE IF NOT EXISTS agent_log_own_baseline(receipt TEXT PRIMARY KEY) WITHOUT ROWID")
    try run("CREATE TABLE IF NOT EXISTS agent_log_own_baseline_runs(id INTEGER PRIMARY KEY CHECK(id=1),receipts INTEGER NOT NULL)")
  }
}

extension ActivityStorage {
  /// Inventory only known app-owned directories and hash-only launch receipts, never log contents.
  /// The database keeps the initial proof even if the filesystem registry is later lost.
  /// Insert-only, once: no code deletes from agent_log_own_baseline, and the Git ownership
  /// memo key (gitOwnershipState) counts on that.
  public func prepareAgentLogCollection() throws {
    try locked { try connection.transaction { try establishAgentLogBaseline() } }
  }
  func establishAgentLogBaseline() throws {
    guard try connection.integer("SELECT count(*) FROM agent_log_own_baseline_runs") == 0 else { return }
    let registry = ownLogSources()
    try registry.registerHome(AppDataPaths.summaryCodexHome(in: appDataDirectory), tool: .codex)
    try registry.registerHome(appDataDirectory.appendingPathComponent("claude"), tool: .claude)
    for tool in AgentLogTool.allCases {
      for name in ["agent-home", "agent-window"] {
        try registry.registerHome(appDataDirectory.appendingPathComponent(name), tool: tool)
      }
    }
    try registry.visitInventory { key in
      try connection.run("INSERT OR IGNORE INTO agent_log_own_baseline VALUES(?)", [.key(key)])
    }
    try connection.run("INSERT INTO agent_log_own_baseline_runs SELECT 1,count(*) FROM agent_log_own_baseline")
  }
}
