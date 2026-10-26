import Core
import Foundation

/// XOR timestamp deltas preserve every IEEE bit, including fractional event times.
/// Presence bits distinguish unknown provenance/deltas from measured zero.
enum CompactInput {
  static let kinds: [InputEventKind] = [.key, .keyUp, .click, .mouseUp, .modifiers, .scroll, .move, .drag]
  static func encode(_ events: [InputObservation]) -> Data {
    var bytes = Data([1]), previous: UInt64 = 0
    func variable(_ value: UInt64) {
      var value = value
      while value >= 128 { bytes.append(UInt8(value & 127) | 128); value >>= 7 }
      bytes.append(UInt8(value))
    }
    func signed(_ value: Int64) { variable(UInt64(bitPattern: (value &<< 1) ^ (value >> 63))) }
    variable(UInt64(events.count))
    for event in events {
      bytes.append(UInt8(kinds.firstIndex(of: event.kind)!))
      var flags: UInt8 = 0
      if event.sourcePID != nil { flags |= 1 }; if event.button != nil { flags |= 2 }
      if event.scrollX != nil { flags |= 4 }; if event.scrollY != nil { flags |= 8 }
      if event.scrollZ != nil { flags |= 16 }; if event.continuousScroll != nil { flags |= 32 }
      if event.monotonicNanoseconds != nil { flags |= 64 }
      bytes.append(flags)
      let time = event.timestamp.bitPattern; variable(time ^ previous); previous = time
      if let v = event.sourcePID { signed(v) }; if let v = event.button { signed(Int64(v)) }
      if let v = event.scrollX { signed(v) }; if let v = event.scrollY { signed(v) }
      if let v = event.scrollZ { signed(v) }; if let v = event.continuousScroll { bytes.append(v ? 1 : 0) }
      if let v = event.monotonicNanoseconds { variable(v) }
    }
    return bytes
  }
  static func decode(_ data: Data) throws -> [InputObservation] {
    let bytes = [UInt8](data); var index = 0, previous: UInt64 = 0
    func byte() throws -> UInt8 {
      guard index < bytes.count else { throw StorageError("Truncated input batch") }
      defer { index += 1 }; return bytes[index]
    }
    func variable() throws -> UInt64 {
      var value: UInt64 = 0
      for shift in stride(from: 0, through: 63, by: 7) {
        let b = try byte()
        guard shift < 63 || b <= 1 else { throw StorageError("Invalid input varint") }
        value |= UInt64(b & 127) << shift
        if b < 128 { return value }
      }
      throw StorageError("Invalid input varint")
    }
    func signed() throws -> Int64 {
      let v = try variable(); return Int64(bitPattern: (v >> 1) ^ (0 &- (v & 1)))
    }
    guard try byte() == 1 else { throw StorageError("Unknown input encoding") }
    let count = try variable()
    guard count <= data.count else { throw StorageError("Invalid input count") }
    var result: [InputObservation] = []
    for _ in 0..<count {
      let kind = Int(try byte()), flags = try byte()
      guard kind < kinds.count else { throw StorageError("Invalid input kind") }
      previous ^= try variable()
      var event = InputObservation(kind: kinds[kind], timestamp: Double(bitPattern: previous))
      if flags & 1 != 0 { event.sourcePID = try signed() }
      if flags & 2 != 0 { event.button = Int(try signed()) }
      if flags & 4 != 0 { event.scrollX = try signed() }; if flags & 8 != 0 { event.scrollY = try signed() }
      if flags & 16 != 0 { event.scrollZ = try signed() }
      if flags & 32 != 0 { event.continuousScroll = try byte() != 0 }
      if flags & 64 != 0 { event.monotonicNanoseconds = try variable() }
      result.append(event)
    }
    guard index == bytes.count else { throw StorageError("Trailing input bytes") }
    return result
  }
}
