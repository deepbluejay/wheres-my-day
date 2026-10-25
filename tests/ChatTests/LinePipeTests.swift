import Darwin
import Foundation
import Outbound
import XCTest

final class LinePipeTests: XCTestCase {
  // A request may split inside a UTF-8 character; several replies may arrive together.
  func testFragmentsCoalescedLinesAndCleanEOF() throws {
    let input = Pipe(), output = Pipe()
    let stream = try LinePipe(input: input.fileHandleForReading, output: output.fileHandleForWriting)
    let bytes = Data("{\"text\":\"가\"}\n".utf8)
    DispatchQueue.global().async {
      for byte in bytes {
        try! input.fileHandleForWriting.write(contentsOf: Data([byte]))
        usleep(1000)
      }
      try! input.fileHandleForWriting.write(contentsOf: Data("second\nthird\n".utf8))
      try! input.fileHandleForWriting.close()
    }
    XCTAssertEqual(try stream.readLine(), Data("{\"text\":\"가\"}".utf8))
    XCTAssertEqual(try stream.readLine(), Data("second".utf8))
    XCTAssertEqual(try stream.readLine(), Data("third".utf8))
    XCTAssertNil(try stream.readLine())
  }

  func testPartialEOFLineBoundCancellationAndDeadline() throws {
    for (text, expected): (String, LinePipeError) in [("partial", .incompleteLine), (String(repeating: "x", count: 65), .lineLimit)] {
      let input = Pipe(), output = Pipe()
      let stream = try LinePipe(input: input.fileHandleForReading, output: output.fileHandleForWriting, lineLimit: 64)
      try input.fileHandleForWriting.write(contentsOf: Data(text.utf8)); try input.fileHandleForWriting.close()
      XCTAssertThrowsError(try stream.readLine()) { XCTAssertEqual($0 as? LinePipeError, expected) }
    }
    let input = Pipe(), output = Pipe()
    let stream = try LinePipe(input: input.fileHandleForReading, output: output.fileHandleForWriting)
    XCTAssertThrowsError(try stream.readLine(cancelled: { true })) { XCTAssertEqual($0 as? LinePipeError, .cancelled) }
    XCTAssertThrowsError(try stream.readLine(deadline: 0)) { XCTAssertEqual($0 as? LinePipeError, .timeout) }
    try output.fileHandleForReading.close()
    try stream.send(Data("request".utf8))
    XCTAssertThrowsError(try stream.readLine()) { XCTAssertEqual($0 as? LinePipeError, .io) }
  }

  // A request larger than the pipe buffer must drain while the peer stays connected.
  func testBackpressurePreservesEveryOutgoingByte() throws {
    let input = Pipe(), output = Pipe()
    let stream = try LinePipe(input: input.fileHandleForReading, output: output.fileHandleForWriting)
    let payload = Data(repeating: 120, count: 500_000)
    let drained = expectation(description: "peer consumed the complete line")
    DispatchQueue.global().async {
      var received = Data(), buffer = [UInt8](repeating: 0, count: 4096)
      while received.count < payload.count + 1 {
        let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
        if count <= 0 { break }
        received.append(contentsOf: buffer.prefix(count))
      }
      XCTAssertEqual(received, payload + Data([10]))
      try! input.fileHandleForWriting.write(contentsOf: Data("reply\n".utf8))
      drained.fulfill()
    }
    try stream.send(payload)
    XCTAssertEqual(try stream.readLine(deadline: ProcessInfo.processInfo.systemUptime + 3), Data("reply".utf8))
    wait(for: [drained], timeout: 3)
  }
}
