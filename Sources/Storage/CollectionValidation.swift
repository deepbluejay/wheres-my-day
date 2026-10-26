import Core
import Foundation

struct CollectionReplayFailure: Error {
  // Never include payloads or application labels in operational errors.
}

func validatedCollectionSecond(_ time: Double) throws -> Int {
  guard time.isFinite, time >= Double(Int.min), time < Double(Int.max) else {
    throw StorageError("Invalid collection timestamp")
  }
  return Int(floor(time))
}

extension CollectionRecord {
  // Decode and admission share semantic validation. Policy/SQL failures happen
  // outside the decoder's damage catch, so retryable work is never quarantined.
  func validate() throws {
    if let storageVersion, !(10...SQLiteConnection.schemaVersion).contains(storageVersion) {
      throw StorageError("Unsupported collection envelope version")
    }
    guard (observation != nil) != (screen != nil), time < Int.max else {
      throw StorageError("Malformed collection envelope")
    }
    if let metadataObservedAt { _ = try validatedCollectionSecond(metadataObservedAt) }
    if let observation {
      guard observation.sample.ts == time, metadataObservedAt == nil, screenJSON == nil else {
        throw StorageError("Collection parent and observation disagree")
      }
      if let observed = observation.sample.observedAt { _ = try validatedCollectionSecond(observed) }
      let inline = observation.sample.inputEvents
      let compact = try observationEvents.map(CompactInput.decode)
      if let compact, !inline.isEmpty, compact != inline { throw StorageError("Conflicting collection input") }
      for event in inline + (compact ?? []) { _ = try validatedCollectionSecond(event.timestamp) }
      if let observationEvents, CompactInput.encode(compact!) != observationEvents {
        throw StorageError("Noncanonical collection input")
      }
    } else {
      if metadataObservedAt == nil,
        !documentKey.isEmpty || screen!.document != nil || screen!.browserAddress != nil {
        guard try validatedCollectionSecond(Double(time)) == time else {
          throw StorageError("Implicit collection metadata time disagrees")
        }
      }
      guard observationEvents == nil else { throw StorageError("Input without collection observation") }
      if let screenJSON {
        guard try JSONDecoder().decode(ScreenTextPayload.self, from: Data(screenJSON.utf8)) == screen else {
          throw StorageError("Collection payloads disagree")
        }
      }
    }
  }
}
