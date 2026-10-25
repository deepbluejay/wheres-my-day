import Core
import Darwin
import Foundation

/// The sign-in callback listener. Bound to 127.0.0.1 only and started before the browser opens.
/// Answers only GET on the callback path; anything else gets 404 or 400 and the wait continues.
final class ChatGPTLoopbackListener {
  static let requestLimit = 16 * 1024
  /// How long one connection may stay open without sending a complete request.
  static let idleWindow: TimeInterval = 5
  /// Connections read at once; the oldest is dropped beyond this.
  static let connectionLimit = 8
  let port: UInt16
  private let socket: Int32
  private let lock = NSLock()
  private var closed = false
  /// Prefers the given port; when it is taken, the system picks one (only the port may vary).
  init(preferredPort: UInt16) throws {
    if preferredPort != 0, let bound = Self.bind(port: preferredPort) { socket = bound.0; port = bound.1 }
    else if let bound = Self.bind(port: 0) { socket = bound.0; port = bound.1 }
    else { throw ChatGPTSignInError.listener }
  }
  deinit { close() }
  var redirectURI: String { "http://127.0.0.1:\(port)" + ChatGPTOAuthConfiguration.callbackPath }
  private static func bind(port: UInt16) -> (Int32, UInt16)? {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    var noSignal: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(descriptor, 8) == 0 else { Darwin.close(descriptor); return nil }
    var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    return (descriptor, UInt16(bigEndian: actual.sin_port))
  }
  func close() {
    lock.lock(); defer { lock.unlock() }
    guard !closed else { return }
    closed = true; Darwin.close(socket)
  }
  /// Waits until `respond` accepts a callback request and returns its query values. Every request on the
  /// callback path gets the status and page `respond` picks; one it does not accept (another attempt's
  /// state, a stale tab, a forged request) is answered and the wait goes on until the deadline.
  /// Several connections are read at once, so an idle one (a browser's preconnect) never holds up the callback.
  func waitForCallback(until deadline: TimeInterval, cancelled: () -> Bool,
    respond: ([String: String]) -> (status: Int, page: String, accept: Bool)) throws -> [String: String] {
    var clients: [Client] = []
    defer { clients.forEach { Darwin.close($0.descriptor) } }
    while true {
      if cancelled() { throw ChatGPTSignInError.cancelled }
      let now = ProcessInfo.processInfo.systemUptime
      if now >= deadline { throw ChatGPTSignInError.timedOut }
      clients.removeAll { client in
        guard now >= client.deadline else { return false }
        Self.reply(client.descriptor, status: 400, page: ""); Darwin.close(client.descriptor); return true
      }
      var descriptors = [pollfd(fd: socket, events: Int16(POLLIN), revents: 0)]
        + clients.map { pollfd(fd: $0.descriptor, events: Int16(POLLIN), revents: 0) }
      guard poll(&descriptors, nfds_t(descriptors.count), 50) > 0 else { continue }
      // Reads first, in reverse, so removing a finished connection never shifts one not yet read.
      for index in clients.indices.reversed() where descriptors[index + 1].revents != 0 {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(clients[index].descriptor, &buffer, buffer.count)
        if count < 0 && errno == EAGAIN { continue }
        if count > 0 { clients[index].received.append(buffer, count: count) }
        let received = clients[index].received
        let complete = received.range(of: Data("\r\n\r\n".utf8)) != nil
        if count > 0 && !complete && received.count < Self.requestLimit { continue }
        let client = clients.remove(at: index).descriptor
        defer { Darwin.close(client) }
        guard complete, let target = Self.requestTarget(received) else { Self.reply(client, status: 400, page: ""); continue }
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts[0] == ChatGPTOAuthConfiguration.callbackPath else { Self.reply(client, status: 404, page: ""); continue }
        let query = ChatGPTForm.decode(parts.count > 1 ? String(parts[1]) : "")
        let answer = respond(query)
        Self.reply(client, status: answer.status, page: answer.page)
        if answer.accept { return query }
      }
      if descriptors[0].revents != 0 {
        let accepted = accept(socket, nil, nil)
        if accepted >= 0 {
          var noSignal: Int32 = 1
          setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
          _ = fcntl(accepted, F_SETFL, fcntl(accepted, F_GETFL) | O_NONBLOCK)
          if clients.count >= Self.connectionLimit { Darwin.close(clients.removeFirst().descriptor) }
          clients.append(Client(descriptor: accepted, deadline: min(deadline, now + Self.idleWindow)))
        }
      }
    }
  }
  private struct Client {
    let descriptor: Int32
    let deadline: TimeInterval
    var received = Data()
  }
  /// The target of a `GET <target> HTTP/1.x` request line, or nil for anything else.
  private static func requestTarget(_ received: Data) -> String? {
    guard let line = received.split(separator: UInt8(ascii: "\r"), maxSplits: 1).first,
      let text = String(data: Data(line), encoding: .utf8) else { return nil }
    let fields = text.split(separator: " ")
    guard fields.count == 3, fields[0] == "GET", fields[2].hasPrefix("HTTP/1.") else { return nil }
    return String(fields[1])
  }
  private static func reply(_ client: Int32, status: Int, page: String) {
    let reason = status == 200 ? "OK" : status == 404 ? "Not Found" : "Bad Request"
    let body = Data(page.utf8)
    let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
      + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
    let bytes = [UInt8](Data(head.utf8) + body)
    var sent = 0
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while sent < bytes.count, ProcessInfo.processInfo.systemUptime < deadline {
      let count = bytes[sent...].withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
      if count > 0 { sent += count } else if errno != EAGAIN { break } else { usleep(5_000) }
    }
  }
}
