import Core
import Darwin
import Foundation

public struct FileVaultReader: FileVaultStatusSource {
  public static let statusTimeoutSeconds: TimeInterval = 10
  private let run: (URL, [String]) throws -> (String, Int32)
  public init(run: @escaping (URL, [String]) throws -> (String, Int32) = {
    try FileVaultReader.runStatus($0, arguments: $1)
  }) {
    self.run = run
  }
  public func fileVaultStatus() -> FileVaultStatus {
    guard let (output, status) = try? run(URL(fileURLWithPath: "/usr/bin/fdesetup"), ["status"]), status == 0 else { return .unknown }
    switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "FileVault is On.": return .on
    case "FileVault is Off.": return .off
    // In-progress encryption does not establish full-disk protection.
    default: return .unknown
    }
  }
  public static func runStatus(_ executable: URL, arguments: [String],
    timeout: TimeInterval = statusTimeoutSeconds) throws -> (String, Int32) {
    let child = Process(), output = Pipe()
    child.executableURL = executable; child.arguments = arguments
    child.standardOutput = output; child.standardError = FileHandle.nullDevice
    child.standardInput = FileHandle.nullDevice
    try child.run()
    try output.fileHandleForWriting.close()
    defer { try? output.fileHandleForReading.close() }
    let fd = output.fileHandleForReading.fileDescriptor
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var data = Data(), eof = false
    // A closed output pipe does not imply the process has exited.
    while !eof || child.isRunning {
      var buffer = [UInt8](repeating: 0, count: 4096)
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
      else if count == 0 { eof = true }
      else if errno != EAGAIN && errno != EINTR {
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
        return ("", -1)
      }
      if ProcessInfo.processInfo.systemUptime >= deadline {
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
        return ("", -1)
      }
      if count <= 0 { Thread.sleep(forTimeInterval: 0.01) }
    }
    child.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), child.terminationReason == .exit ? child.terminationStatus : -1)
  }
}
