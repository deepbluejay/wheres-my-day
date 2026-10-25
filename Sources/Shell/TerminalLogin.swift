import AppKit
import Core
import Foundation

/// Opens the login script in Terminal as a document. No Apple events are sent, so no automation
/// permission is asked; Terminal runs the script in the person's own shell environment.
public enum TerminalLogin {
  static let bundleID = "com.apple.Terminal"
  public typealias Opener = (_ document: URL, _ terminal: URL, _ done: @escaping (Error?) -> Void) -> Void
  /// Waits for Launch Services to say whether Terminal took the script, without holding a thread meanwhile.
  public static func open(_ script: URL) async throws {
    try await open(script, terminal: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)) { document, terminal, done in
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.open([document], withApplicationAt: terminal, configuration: configuration) { _, error in done(error) }
    }
  }
  /// A refused or failed open is reported. One still pending at the limit is not: Terminal may yet open it.
  static func open(_ script: URL, terminal: URL?, limit: TimeInterval = 30, opener: Opener) async throws {
    guard let terminal else { throw SubscriptionConnectionError.terminalFailed }
    let failed: Bool? = await withCheckedContinuation { continuation in
      // The first of the completion handler and the limit resumes; the other finds it already resumed.
      let once = TerminalLoginOnce(continuation)
      opener(script, terminal) { error in once.resume(error != nil) }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) { once.resume(nil) }
    }
    if failed == true { throw SubscriptionConnectionError.terminalFailed }
  }
}

/// Resumes a continuation exactly once, from whichever side answers first.
private final class TerminalLoginOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Bool?, Never>?
  init(_ continuation: CheckedContinuation<Bool?, Never>) { self.continuation = continuation }
  func resume(_ value: Bool?) {
    lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
    pending?.resume(returning: value)
  }
}
