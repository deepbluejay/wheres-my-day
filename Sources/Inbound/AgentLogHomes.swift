import Core
import Foundation

/// Shared file plumbing only. Adapters have no mutable state and run on the shell's background queue.
struct ToolLogFiles {
  let tool: AgentLogTool
  let userHome: String
  let processes: AgentLogProcessSource
  var summaryCodexHome: URL? = nil
  var appDataDirectory: URL? = nil
  var excludedSummaryHome: URL {
    (summaryCodexHome ?? AppDataPaths.summaryCodexHome(in: appDataDirectory
      ?? AppDataPaths.directory(in: URL(fileURLWithPath: userHome))))
      .resolvingSymlinksInPath().standardizedFileURL
  }
  func listing() throws -> AgentLogListing {
    let homes = try processes.processes().filter { $0.tool == tool }.compactMap { process in
      // A process may exit, or deny inspection. Defaults and the other processes' homes still get scanned.
      try? processes.homeVariable(tool.homeVariable, processID: process.pid)
    }
    // Only the summary's Codex home is the app's own. Claude runs in the person's home without a saved
    // session, so the person's Claude folder is read like any other.
    let folders = AgentLogPolicy.folders(tool: tool, userHome: userHome, foundHomes: homes).filter { folder in
      guard tool == .codex else { return true }
      let home = URL(fileURLWithPath: folder).deletingLastPathComponent()
      return (try? FileLocation.same(home, excludedSummaryHome)) == false
    }
    return try AgentLogFiles.listing(folders)
  }
}
