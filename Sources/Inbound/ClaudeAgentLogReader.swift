import Core
import Foundation

// Immutable tool adapter, called only by the shell background task.
public struct ClaudeAgentLogReader: AgentLogReader {
  public let name = "claude-logs"
  private let filesSource: ToolLogFiles
  public init(userHome: String, processes: AgentLogProcessSource, appDataDirectory: URL? = nil) {
    filesSource = ToolLogFiles(tool: .claude, userHome: userHome, processes: processes, appDataDirectory: appDataDirectory)
  }
  public func files() throws -> [AgentLogFile] { try listing().files }
  public func listing() throws -> AgentLogListing { try filesSource.listing() }
  public func read(_ file: AgentLogFile, position: LogPosition?, at time: Int) throws -> AgentLogBatch {
    try AgentLogFiles.read(file, tool: .claude, position: position, at: time)
  }
}
