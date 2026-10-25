import Core
import CryptoKit
import Darwin
import Foundation

public enum AgentLogReadError: Error { case fileChanged, fileUnavailable, invalidState, processUnavailable }

/// Background-task only. File handles are local to each read, never shared with the recorder thread.
public enum AgentLogFiles {
  // Chosen batch and line bounds, not measured. Oversized complete lines are counted, never parsed as prompts.
  public static let batchBytes = 1 << 20
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
    var identities = Set<String>()
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
        let identity = "\(info.st_dev):\(info.st_ino)"
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
    _ file: AgentLogFile, tool: AgentLogTool, position: LogPosition?, at time: Int
  ) throws -> AgentLogBatch {
    try readFile(file, tool: tool, position: position, at: time, beforeFinalCheck: {})
  }
  // The final-check seam lets invented files shrink deterministically without a timing race.
  static func readFile(
    _ file: AgentLogFile, tool: AgentLogTool, position: LogPosition?, at time: Int,
    beforeFinalCheck: () throws -> Void
  ) throws -> AgentLogBatch {
    let continuing = AgentLogPolicy.continues(position, file: file)
    var state: AgentLogState
    do { state = continuing ? try AgentLogState.decode(position?.state ?? "") : AgentLogState() }
    catch { throw AgentLogReadError.invalidState }
    let handle: FileHandle
    do { handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file.path)) }
    catch { throw AgentLogReadError.fileUnavailable }
    defer { try? handle.close() }
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0,
      Int(info.st_dev) == file.device, Int(info.st_ino) == file.inode
    else { throw AgentLogReadError.fileChanged }
    if tool == .codex, continuing, !state.metadataRead {
      // Converted cursors predate persisted tool marks. Recover them from the header before resuming.
      let header = try handle.read(upToCount: longestLineBytes + 1) ?? Data()
      if let end = header.firstIndex(of: 10), let text = String(data: header[..<end], encoding: .utf8) {
        var headerState = state
        _ = AgentLogParser.parse(text, tool: tool, file: file.path, state: &headerState, fingerprint: fingerprint)
        state.ignoredSession = headerState.ignoredSession
        state.metadataRead = headerState.metadataRead
      }
    }
    let initial = continuing ? position?.offset ?? 0 : 0
    do { try handle.seek(toOffset: UInt64(initial)) } catch { throw AgentLogReadError.fileUnavailable }
    var offset = initial
    var line = Data()
    var lineBytes = 0
    var malformed = 0
    var evidence: [EvidenceText] = []
    var ignored: [AgentLogIgnore: Int] = [:]
    var stop = false
    while !stop {
      let chunk: Data
      do { chunk = try handle.read(upToCount: 65536) ?? Data() }
      catch { throw AgentLogReadError.fileUnavailable }
      if chunk.isEmpty { break }
      for byte in chunk {
        if byte != 10 {
          lineBytes += 1
          if lineBytes <= longestLineBytes { line.append(byte) }
          continue
        }
        if lineBytes > longestLineBytes {
          malformed += 1
        } else if lineBytes > 0 {
          if let text = String(data: line, encoding: .utf8) {
            switch AgentLogParser.parse(
              text, tool: tool, file: file.path, state: &state,
              logsRelativePath: file.logsRelativePath, fingerprint: fingerprint)
            {
            case .prompt(let prompt): evidence.append(prompt)
            case .excluded(let reason): ignored[reason, default: 0] += 1
            case .malformed: malformed += 1
            case .ignored: break
            }
          } else {
            malformed += 1
          }
        }
        offset += lineBytes + 1
        line = Data()
        lineBytes = 0
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
    var batch = AgentLogBatch(
      evidence: evidence,
      position: LogPosition(
        path: file.path, device: file.device, inode: file.inode, offset: offset,
        state: try state.encoded(), seenAt: time),
      malformedLines: malformed)
    batch.ignored = ignored
    return batch
  }
  static func fingerprint(_ text: String) -> String {
    SHA256.hash(data: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}
