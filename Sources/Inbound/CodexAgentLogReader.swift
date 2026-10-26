import Core
import Foundation

// Immutable tool adapter, called only by the shell background task.
public struct CodexAgentLogReader: AgentLogReader {
  public let name = "codex-logs"
  private let filesSource: ToolLogFiles
  public init(userHome: String, processes: AgentLogProcessSource, summaryCodexHome: URL? = nil, appDataDirectory: URL? = nil) {
    filesSource = ToolLogFiles(tool: .codex, userHome: userHome, processes: processes, summaryCodexHome: summaryCodexHome, appDataDirectory: appDataDirectory)
  }
  public func files() throws -> [AgentLogFile] { try listing().files }
  public func listing() throws -> AgentLogListing { try filesSource.listing() }
  public func read(_ file: AgentLogFile, position: LogPosition?, at time: Int) throws -> AgentLogBatch {
    try AgentLogFiles.read(file, tool: .codex, position: position, at: time, ownSources: AgentLogFiles.ownSources(
      appDataDirectory: filesSource.appDataDirectory ?? AppDataPaths.directory(in: URL(fileURLWithPath: filesSource.userHome))))
  }
}
