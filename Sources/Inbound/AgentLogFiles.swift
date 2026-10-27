import Core
import CryptoKit
import Darwin
import Foundation

public enum AgentLogReadError: Error { case fileChanged, fileUnavailable, invalidState, processUnavailable }

/// Background-task only. File handles are local to each read, never shared with the recorder thread.
public enum AgentLogFiles {
  // Chosen batch and line bounds, not measured. Oversized complete lines retain a bounded masked prefix and an explicit truncation status.
  public static func ownSources(appDataDirectory: URL) -> AgentLogOwnSources {
    AgentLogOwnSources(appDataDirectory: appDataDirectory, digest: {
      SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
    })
  }
  public static let batchBytes = 1 << 20
  public static let batchRetainedBytes = 4 << 20
  public static let longestLineBytes = 16 << 20
  public static func enumerate(_ folders: [String]) throws -> [AgentLogFile] {
    try listing(folders).files
  }
  public static func listing(_ folders: [String]) throws -> AgentLogListing {
    try listing(folders, enumerate: { root, onError in
      FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [], errorHandler: onError)
    })
  }
  // The enumeration seam supplies invented errors without OS permissions or a filesystem timing race.
  static func listing(
    _ folders: [String],
    enumerate: (URL, @escaping (URL, Error) -> Bool) -> FileManager.DirectoryEnumerator?
  ) throws -> AgentLogListing {
    var failures = 0
    var found: [AgentLogFile] = []
    struct PhysicalFile: Hashable { let device: Int; let inode: Int }
    var identities = Set<PhysicalFile>()
    for folder in folders.sorted() {
      let root = URL(fileURLWithPath: folder).resolvingSymlinksInPath()
      var folderInfo = stat()
      if stat(folder, &folderInfo) != 0 {
        if errno == ENOENT { continue }
        failures += 1
        continue
      }
      guard (folderInfo.st_mode & S_IFMT) == S_IFDIR else {
        failures += 1
        continue
      }
      var error: Error?
      let walker = enumerate(root, { _, failure in
        error = failure
        return true
      })
      guard let walker else {
        failures += 1
        continue
      }
      for case let url as URL in walker where url.pathExtension == "jsonl" {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        var info = stat()
        guard stat(canonical, &info) == 0 else { continue }
        guard (info.st_mode & S_IFMT) == S_IFREG else { continue }
        let identity = PhysicalFile(device: Int(info.st_dev), inode: Int(info.st_ino))
        guard identities.insert(identity).inserted else { continue }
        let relative = url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
        found.append(AgentLogFile(
          path: canonical, device: Int(info.st_dev), inode: Int(info.st_ino), size: Int(info.st_size),
          logsRelativePath: relative))
      }
      if error != nil { failures += 1 }
    }
    return AgentLogListing(files: found.sorted { $0.path < $1.path }, folderFailures: failures)
  }
  public static func read(
    _ file: AgentLogFile, tool: AgentLogTool, position: LogPosition?, at time: Int,
    ownSources: AgentLogOwnSources? = nil
  ) throws -> AgentLogBatch {
    try readFile(file, tool: tool, position: position, at: time, ownSources: ownSources, beforeFinalCheck: {})
  }
  // The final-check seam lets invented files shrink deterministically without a timing race.
  static func readFile(
    _ file: AgentLogFile, tool: AgentLogTool, position: LogPosition?, at time: Int,
    ownSources: AgentLogOwnSources? = nil, beforeFinalCheck: () throws -> Void
  ) throws -> AgentLogBatch {
    let continuing = AgentLogPolicy.continues(position, file: file)
    var state: AgentLogState
    do { state = continuing ? try AgentLogState.decode(position?.state ?? "") : AgentLogState() }
    catch { throw AgentLogReadError.invalidState }
    // Canonical paths can be shared by discovery roots. Parser identities are tool-specific.
    let recoverMetadata = continuing && (state.tool != tool.rawValue || state.metadataVersion != 5)
    if recoverMetadata {
      state.resetMetadataForRecovery()
    }
    state.tool = tool.rawValue
    let handle: FileHandle
    do { handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file.path)) }
    catch { throw AgentLogReadError.fileUnavailable }
    defer { try? handle.close() }
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0,
      Int(info.st_dev) == file.device, Int(info.st_ino) == file.inode
    else { throw AgentLogReadError.fileChanged }
    if state.metadataRecoveryOffset != nil {
      try recoverCheckpointMetadata(handle, through: position?.offset ?? 0, tool: tool, file: file.path, state: &state)
      if state.metadataRecoveryOffset != nil {
        try beforeFinalCheck()
        guard fstat(handle.fileDescriptor, &info) == 0, Int(info.st_size) >= (position?.offset ?? 0)
        else { throw AgentLogReadError.fileChanged }
        var batch = AgentLogBatch(evidence: [], position: LogPosition(path: file.path, device: file.device,
          inode: file.inode, offset: position?.offset ?? 0, state: try state.encoded(), seenAt: time), malformedLines: 0)
        batch.ownershipDeferred = true
        return batch
      }

    }
    let checkpointSubjects = [state.ownershipSession].compactMap { $0 }
    try evaluateOwnership(&state, sessions: checkpointSubjects, file: file.path, tool: tool, ownSources: ownSources)
    try preflightOwnership(handle, state: &state, size: Int(info.st_size), tool: tool, ownSources: ownSources)
    let initial = continuing ? position?.offset ?? 0 : 0
    do { try handle.seek(toOffset: UInt64(initial)) } catch { throw AgentLogReadError.fileUnavailable }
    var offset = initial
    var line = Data()
    var lineBytes = 0
    var metadata = AgentLogMetadata()
    var malformed = 0
    var evidence: [EvidenceText] = []
    var events: [AgentLogEvent] = []
    var retainedBytes = 0
    var ignored: [AgentLogIgnore: Int] = [:]
    var stop = false
    while !stop {
      let chunk: Data
      do { chunk = try autoreleasepool { try handle.read(upToCount: 65536) ?? Data() } }
      catch { throw AgentLogReadError.fileUnavailable }
      if chunk.isEmpty { break }
      for byte in chunk {
        if byte != 10 {
          lineBytes += 1
          metadata.consume(byte)
          if lineBytes <= longestLineBytes { line.append(byte) }
          continue
        }
        let beforeRecord = state
        let parsed: AgentLogEvent? = state.ownWorkingFolder == true || state.ignoredSession == .ownWindow ? nil
          : autoreleasepool(invoking: { AgentLogEventParser.parse(
          line, byteCount: lineBytes, offset: offset, observedAt: time, tool: tool,
          file: file.path, state: &state, logsRelativePath: file.logsRelativePath, metadata: metadata, fingerprint: fingerprint) })
        try evaluateOwnership(&state, sessions: [parsed?.explicitSession].compactMap { $0 },
          file: nil, tool: tool, ownSources: ownSources)
        if state.ownWorkingFolder == true || state.ignoredSession == .ownWindow {
          events.removeAll()
          evidence.removeAll()
          retainedBytes = 0
          ignored[.ownWindow, default: 0] += 1
        } else if var event = parsed {
          if var prompt = event.prompt, prompt.agentLogIdentity?.hasPrefix(tool.rawValue + ":legacy:") == true {
            prompt.sourceID = "\(tool.rawValue):occurrence:\(file.device):\(file.inode):\(offset)"
            event.prompt = prompt
            event.canonicalIdentity = prompt.agentLogIdentity
          }
          if !events.isEmpty && retainedBytes + event.retainedByteEstimate > batchRetainedBytes {
            state = beforeRecord
            stop = true
            break
          }
          retainedBytes += event.retainedByteEstimate
          events.append(event)
          if let prompt = event.prompt { evidence.append(prompt) }
          for flag in event.flags where flag.hasPrefix("promptProjection:") {
            if let reason = AgentLogIgnore(rawValue: String(flag.dropFirst("promptProjection:".count))) {
              ignored[reason, default: 0] += 1
            }
          }
          if ["truncated", "invalidUTF8", "invalidJSON", "unknownSchema"].contains(event.parseStatus)
            || event.flags.contains("promptProjection:malformed") { malformed += 1 }
        } else { ignored[.ownWindow, default: 0] += 1 }
        offset += lineBytes + 1
        line = Data()
        lineBytes = 0
        metadata = AgentLogMetadata()
        if offset - initial >= batchBytes {
          stop = true
          break
        }
      }
    }
    try beforeFinalCheck()
    // An unfinished line is reread next scan. Its bytes never enter checkpoint state.
    guard fstat(handle.fileDescriptor, &info) == 0, Int(info.st_size) >= offset else {
      throw AgentLogReadError.fileChanged
    }
    if state.ownWorkingFolder == true || state.ignoredSession == .ownWindow {
      if let session = state.ownedSession {
        try ownSources?.registerSession(session, tool: tool)
      }
      try ownSources?.registerPath(URL(fileURLWithPath: file.path), tool: tool)
    }
    var batch = AgentLogBatch(
      evidence: evidence,
      position: LogPosition(
        path: file.path, device: file.device, inode: file.inode, offset: offset,
        state: try state.encoded(), seenAt: time),
      malformedLines: malformed)
    batch.ignored = ignored
    batch.events = events
    return batch
  }
  private static func recoverCheckpointMetadata(_ handle: FileHandle, through offset: Int,
    tool: AgentLogTool, file: String, state: inout AgentLogState) throws {
    let initial = state.metadataRecoveryOffset ?? 0
    guard initial >= 0, initial <= offset else { throw AgentLogReadError.invalidState }
    try handle.seek(toOffset: UInt64(initial))
    var consumed = initial
    var metadata = state.metadataRecoveryScanner ?? AgentLogMetadata()
    while consumed < offset {
      let chunk = try autoreleasepool { try handle.read(upToCount: min(65536, offset - consumed)) ?? Data() }
      guard !chunk.isEmpty else { throw AgentLogReadError.fileChanged }
      for byte in chunk {
        consumed += 1
        if byte == 10 {
          metadata.apply(tool: tool, file: file, state: &state, fingerprint: fingerprint)
          metadata = AgentLogMetadata()
        } else { metadata.consume(byte) }
        // At most one bounded token or digest block finishes before saving, including inside large values.
        if consumed - initial >= batchBytes && metadata.checkpointSafe {
          state.metadataRecoveryOffset = consumed
          state.metadataRecoveryScanner = metadata
          if consumed == offset {
            state.metadataRecoveryOffset = nil
            state.metadataRecoveryScanner = nil
          }
          return
        }
      }
    }
    state.metadataRecoveryOffset = nil
    state.metadataRecoveryScanner = nil
  }
  /// Bounded lookahead supplements launch receipts. Missing metadata never blocks external sources.
  private static func preflightOwnership(_ handle: FileHandle, state: inout AgentLogState, size: Int,
    tool: AgentLogTool, ownSources: AgentLogOwnSources?) throws {
    if state.ownershipScanOffset < 0 || state.ownershipScanOffset > size {
      state.ownershipScanOffset = 0
      state.ownershipSession = nil
    }
    try handle.seek(toOffset: UInt64(state.ownershipScanOffset))
    let initial = state.ownershipScanOffset
    var metadata = AgentLogMetadata()
    var lineBytes = 0
    // Lookahead metadata belongs to its own cursor, never to earlier ordinary records.
    var lookahead = AgentLogState()
    lookahead.session = state.ownershipScanOffset > 0 ? state.ownershipSession : nil
    while true {
      let chunk = try autoreleasepool { try handle.read(upToCount: 65536) ?? Data() }
      if chunk.isEmpty { return }
      for byte in chunk {
        if byte != 10 {
          lineBytes += 1
          metadata.consume(byte)
          continue
        }
        AgentLogTransitionReducer.apply(metadata.facts(tool: tool), tool: tool, state: &lookahead)
        try evaluateOwnership(&lookahead, sessions: [metadata.explicitSession(tool: tool)].compactMap { $0 },
          file: nil, tool: tool, ownSources: ownSources)
        state.ownershipSession = lookahead.session
        // Independent cursor: only positive proof crosses into ordinary attribution.
        if lookahead.ownWorkingFolder == true {
          state.ownedSession = lookahead.ownedSession ?? state.ownedSession
          state.ownWorkingFolder = true
          state.ignoredSession = .ownWindow
        }
        state.ownershipScanOffset += lineBytes + 1
        metadata = AgentLogMetadata()
        lineBytes = 0
        if lookahead.ownWorkingFolder == true || state.ownedSession != nil || state.ownershipScanOffset - initial >= batchBytes { return }
      }
    }
  }
  private static func evaluateOwnership(_ state: inout AgentLogState, sessions: [AgentLogSessionSubject] = [],
    file: String?, tool: AgentLogTool, ownSources: AgentLogOwnSources?) throws {
    let decision = try AgentLogOwnership.evaluate(state: state, sessions: [state.session].compactMap { $0 } + sessions,
      pathOwned: file.map { try ownSources?.contains(path: $0, tool: tool) == true } ?? false,
      containsSession: { try ownSources?.containsSession($0, tool: tool) == true })
    decision.update(&state)
  }
  static func fingerprint(_ text: String) -> String {
    SHA256.hash(data: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}
