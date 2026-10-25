import Darwin
import Foundation

public enum LinePipeError: Error, Equatable {
  case io, incompleteLine, lineLimit, outputLimit, cancelled, timeout
}

/// One owner frames both directions. Protocol parsers receive complete byte lines,
/// so a short pipe read or a split UTF-8 character cannot become a partial message.
public final class LinePipe {
  public static let defaultLineLimit = 1_048_576
  private let input: FileHandle
  private let output: FileHandle
  private let inputFlags: Int32
  private let outputFlags: Int32
  private let lineLimit: Int
  private let outgoingLimit: Int
  private let receivedLimit: Int?
  private var incoming = Data()
  private var outgoing = Data()
  private var received = 0
  private var eof = false

  public init(input: FileHandle, output: FileHandle, lineLimit: Int = LinePipe.defaultLineLimit,
    outgoingLimit: Int = LinePipe.defaultLineLimit, receivedLimit: Int? = 64 * LinePipe.defaultLineLimit) throws {
    self.input = input; self.output = output; self.lineLimit = lineLimit
    self.outgoingLimit = outgoingLimit; self.receivedLimit = receivedLimit
    inputFlags = fcntl(input.fileDescriptor, F_GETFL)
    outputFlags = fcntl(output.fileDescriptor, F_GETFL)
    guard lineLimit > 0, outgoingLimit > 0, outgoingLimit <= Int.max / 2,
      inputFlags >= 0, outputFlags >= 0 else { throw LinePipeError.io }
    guard fcntl(input.fileDescriptor, F_SETFL, inputFlags | O_NONBLOCK) == 0 else { throw LinePipeError.io }
    guard fcntl(output.fileDescriptor, F_SETFL, outputFlags | O_NONBLOCK) == 0,
      fcntl(output.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
      _ = fcntl(input.fileDescriptor, F_SETFL, inputFlags)
      _ = fcntl(output.fileDescriptor, F_SETFL, outputFlags)
      throw LinePipeError.io
    }
  }
  deinit {
    _ = fcntl(input.fileDescriptor, F_SETFL, inputFlags)
    _ = fcntl(output.fileDescriptor, F_SETFL, outputFlags)
  }

  public func send(_ line: Data) throws {
    guard line.count <= outgoingLimit, !line.contains(10),
      outgoing.count + line.count + 1 <= 2 * outgoingLimit else { throw LinePipeError.outputLimit }
    outgoing.append(line); outgoing.append(10)
  }

  /// Flushes queued replies while waiting, including when the peer leaves stdin open.
  /// A clean EOF returns nil; EOF inside a frame is always an error.
  public func readLine(deadline: TimeInterval = .infinity, cancelled: () -> Bool = { false }, service: () throws -> Void = {}) throws -> Data? {
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      try service()
      guard !cancelled() else { throw LinePipeError.cancelled }
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw LinePipeError.timeout }
      if !outgoing.isEmpty {
        let count = outgoing.withUnsafeBytes { Darwin.write(output.fileDescriptor, $0.baseAddress, $0.count) }
        if count > 0 { outgoing.removeFirst(count) }
        else if count < 0 && errno != EAGAIN && errno != EINTR { throw LinePipeError.io }
      }
      if let newline = incoming.firstIndex(of: 10) {
        let length = incoming.distance(from: incoming.startIndex, to: newline)
        guard length <= lineLimit else { throw LinePipeError.lineLimit }
        let line = Data(incoming.prefix(length))
        incoming.removeFirst(length + 1)
        return line
      }
      guard incoming.count <= lineLimit else { throw LinePipeError.lineLimit }
      if eof {
        guard incoming.isEmpty else { throw LinePipeError.incompleteLine }
        if outgoing.isEmpty { return nil }
      } else {
        let count = Darwin.read(input.fileDescriptor, &buffer, buffer.count)
        if count > 0 {
          if let receivedLimit {
            guard count <= receivedLimit - received else { throw LinePipeError.lineLimit }
            received += count
          }
          incoming.append(contentsOf: buffer.prefix(count)); continue
        } else if count == 0 { eof = true; continue }
        else if errno != EAGAIN && errno != EINTR { throw LinePipeError.io }
      }
      // Short waits keep cancellation and deadlines responsive without a busy loop.
      var descriptors = [pollfd(fd: eof ? -1 : input.fileDescriptor, events: Int16(POLLIN), revents: 0),
        pollfd(fd: outgoing.isEmpty ? -1 : output.fileDescriptor, events: Int16(POLLOUT), revents: 0)]
      let result = Darwin.poll(&descriptors, nfds_t(descriptors.count), 10)
      if result < 0 && errno != EINTR { throw LinePipeError.io }
    }
  }
}
