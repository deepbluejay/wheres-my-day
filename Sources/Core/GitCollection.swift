import Foundation

/// Transient cwd is resolved before masking. Only the masked link is persisted.
public struct GitWorkingFolder {
  public var tool: AgentLogTool?
  public var folder: String
  public var session: String
  public var source: String
  public var sourceIdentity: AgentLogPhysicalSource?
  public var physicalSource: AgentLogPhysicalSource { sourceIdentity ?? AgentLogIdentity.decodedPath(source) }
  public var device: Int
  public var inode: Int
  public var time: Int
  public init(folder: String, session: String, source: String, device: Int, inode: Int, time: Int, tool: AgentLogTool? = nil, sourceIdentity: AgentLogPhysicalSource? = nil) {
    self.sourceIdentity = sourceIdentity
    self.tool = tool; self.folder = folder; self.session = session; self.source = source
    self.device = device; self.inode = inode; self.time = time
  }
}
public struct GitRepositoryLocation {
  public var commonDirectory: String
  public var topLevel: String
  public var branch: String
  public var head: String
  public init(commonDirectory: String, topLevel: String, branch: String, head: String) {
    self.commonDirectory = commonDirectory; self.topLevel = topLevel; self.branch = branch; self.head = head
  }
}
public struct GitCommitRecord {
  public var hash: String
  public var authorTime: Int
  public var commitTime: Int
  public var author: String
  public var email: String
  public var message: String
  public init(hash: String, authorTime: Int, commitTime: Int, author: String, email: String, message: String) {
    self.hash = hash; self.authorTime = authorTime; self.commitTime = commitTime
    self.author = author; self.email = email; self.message = message
  }
}
public struct GitChangedFile {
  public var oldPath: String
  public var path: String
  public var added: Int?
  public var deleted: Int?
  public init(oldPath: String = "", path: String, added: Int?, deleted: Int?) {
    self.oldPath = oldPath; self.path = path; self.added = added; self.deleted = deleted
  }
}
