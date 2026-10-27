import Foundation

/// Launches register before starting a child. Hash-only receipts persist ownership without log content.
/// One file per receipt avoids a shared read/modify/write race between the app and recorder processes.
public struct AgentLogOwnSources {
  public enum AuthorityError: Error { case invalidReceipt }
  public static let folderName = "own-agent-log-sources"
  private let directory: URL
  private let digest: (Data) -> String
  private let receiptExists: ((URL) throws -> Bool)?
  private let retainedReceipt: (String) throws -> Bool
  public init(appDataDirectory: URL, digest: @escaping (Data) -> String, retainedReceipt: @escaping (String) throws -> Bool = { _ in false }, receiptExists: ((URL) throws -> Bool)? = nil) {
    self.receiptExists = receiptExists
    self.retainedReceipt = retainedReceipt
    self.digest = digest
    directory = appDataDirectory.appendingPathComponent(Self.folderName)
  }
  private func receipt(_ kind: String, _ value: String, tool: AgentLogTool) -> URL {
    // Only the hash is retained. Exact canonical paths must not collapse when masking hides a suffix.
    let safe = value
    return directory.appendingPathComponent(digest(Data((tool.rawValue + ":" + kind + ":" + safe).utf8)))
  }
  private func exists(_ url: URL) throws -> Bool {
    if try retainedReceipt(url.lastPathComponent) { return true }
    if let receiptExists { return try receiptExists(url) }
    do { return try url.checkResourceIsReachable() }
    catch {
      let failure = error as NSError
      let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
      if failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError,
        underlying?.domain == NSPOSIXErrorDomain && underlying?.code == 2 { return false }
      throw error
    }
  }
  private func register(_ kind: String, _ value: String, tool: AgentLogTool) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let target = receipt(kind, value, tool: tool)
    if FileManager.default.fileExists(atPath: target.path) { return }
    do { try Data().write(to: target, options: .withoutOverwriting) }
    catch { if !FileManager.default.fileExists(atPath: target.path) { throw error } }
  }
  /// Receipt names are one-way hashes; neither receipt contents nor agent files are opened.
  public func visitInventory(_ visit: (String) throws -> Void) throws {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    var failure: Error?
    guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [],
      options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in failure = error; return false }) else {
      throw CocoaError(.fileReadUnknown)
    }
    for case let url as URL in walker {
      let key = url.lastPathComponent
      if key.utf8.count == 64 && key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
        try visit(key)
      }
    }
    if let failure { throw failure }
  }
  public func inventory() throws -> [String] {
    var keys: [String] = []
    try visitInventory { keys.append($0) }
    return keys.sorted()
  }
  public func registerSession(_ input: AgentLogIdentity.DecodedInput, tool: AgentLogTool) throws {
    guard let subject = input.session.subject else { return }
    try registerSession(subject, tool: tool)
  }
  public func registerSession(_ subject: AgentLogSessionSubject, tool: AgentLogTool) throws {
    guard subject.isUsable else { return }
    try register("session", subject.storedKey, tool: tool)
  }
  public func registerHome(_ home: URL, tool: AgentLogTool) throws {
    try register("home", home.resolvingSymlinksInPath().standardizedFileURL.path, tool: tool)
  }
  public func registerPath(_ path: URL, tool: AgentLogTool) throws {
    try register("path", path.resolvingSymlinksInPath().standardizedFileURL.path, tool: tool)
  }
  /// Hash-only candidates retain exact raw path ownership after masking persistence.
  public func authority(path: String, sessions: [AgentLogSessionSubject], tool: AgentLogTool) -> [String] {
    var candidates = sessions.map { receipt("session", $0.storedKey, tool: tool).lastPathComponent }
    var url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    candidates.append(receipt("path", url.path, tool: tool).lastPathComponent)
    for part in url.pathComponents {
      let stem = (part as NSString).deletingPathExtension
      candidates.append(receipt("session", AgentLogIdentity.decoded(stem).component.storedKey, tool: tool).lastPathComponent)
      if tool == .codex, stem.count >= 36 {
        candidates.append(receipt("session", AgentLogIdentity.decoded(String(stem.suffix(36))).component.storedKey, tool: tool).lastPathComponent)
      }
    }
    while url.path != "/" {
      candidates.append(receipt("home", url.path, tool: tool).lastPathComponent)
      url.deleteLastPathComponent()
    }
    return Array(Set(candidates)).sorted()
  }
  public func containsAuthority(_ candidates: [String]) throws -> Bool {
    guard !candidates.isEmpty else { throw AuthorityError.invalidReceipt }
    guard candidates.allSatisfy({ candidate in
      candidate.utf8.count == 64 && candidate.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      })
    }) else { throw AuthorityError.invalidReceipt }
    // An absent registry proves every candidate absent at this admission check.
    for candidate in candidates {
      if try exists(directory.appendingPathComponent(candidate)) { return true }
    }
    return false
  }
  public func containsSession(_ input: AgentLogIdentity.DecodedInput, tool: AgentLogTool) throws -> Bool {
    try containsSession(input.session.subject, tool: tool)
  }
  public func containsSession(_ subject: AgentLogSessionSubject?, tool: AgentLogTool) throws -> Bool {
    guard let subject, subject.isUsable else { return false }
    return try exists(receipt("session", subject.storedKey, tool: tool))
  }
  public func contains(path: String, session: AgentLogSessionSubject? = nil, tool: AgentLogTool) throws -> Bool {
    if try containsSession(session, tool: tool) { return true }
    var url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    if try exists(receipt("path", url.path, tool: tool)) { return true }
    // Claude session folders also cover subagent logs. Codex rollout names end in the thread UUID.
    for part in url.pathComponents {
      let stem = (part as NSString).deletingPathExtension
      if try containsSession(AgentLogIdentity.decoded(stem), tool: tool) { return true }
      if tool == .codex, stem.count >= 36, try containsSession(AgentLogIdentity.decoded(String(stem.suffix(36))), tool: tool) { return true }
    }
    while url.path != "/" {
      if try exists(receipt("home", url.path, tool: tool)) { return true }
      url.deleteLastPathComponent()
    }
    return false
  }
}
