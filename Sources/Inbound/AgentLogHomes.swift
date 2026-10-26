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
    var discoveryFailures = 0
    let discovered: [AgentLogProcess]
    do { discovered = try processes.processes() }
    catch { discovered = []; discoveryFailures += 1 }
    let homes = discovered.filter { $0.tool == tool }.compactMap { process in
      // A process may exit, or deny inspection. Defaults and the other processes' homes still get scanned.
      try? processes.homeVariable(tool.homeVariable, processID: process.pid)
    }
    // Exclude the summary home before enumeration. Launch receipts protect own sessions in shared
    // homes during reading, so the person's ordinary Claude sessions remain discoverable.
    let folders = AgentLogPolicy.folders(tool: tool, userHome: userHome, foundHomes: homes).filter { folder in
      guard tool == .codex else { return true }
      let home = URL(fileURLWithPath: folder).deletingLastPathComponent()
      let excluded = (try? FileLocation.same(home, excludedSummaryHome)) != false
      return !AgentLogOwnership.evaluate(state: AgentLogState(), pathOwned: excluded, containsSession: { _ in false }).excludesSource
    }
    let listing = try AgentLogFiles.listing(folders)
    return AgentLogListing(files: listing.files, folderFailures: listing.folderFailures, discoveryFailures: discoveryFailures)
  }
}
