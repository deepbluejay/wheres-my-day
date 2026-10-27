@testable import Core
import Foundation
@testable import Storage

// This oracle has no dependency on the production gate, receipt maps or SQL
// predicates. The adapter below supplies commands and observes durable rows.
struct GitPublicationModel {
  struct History { var time: Int; var enabled: Bool; var pause: Int? }
  struct Receipt: Equatable { var generation: Int; var days: Int; var forget: Int }
  enum Outcome { case prepared, publishing, complete, refused, expired, interrupted, debt }
  let origin = 1_780_000_000
  var now = 1_780_000_000
  var maintained = 1_780_000_000
  var days = 30
  var enabled = true
  var pause: Int?
  var secure: Bool? = false
  var history = [History(time: 0, enabled: true, pause: nil)]
  var generation = 0
  var forgetRevision = 0
  var forgotten: [Range<Int>] = []
  var revoked = Set<Int>()
  var linked = Set<Int>()
  var erased = Set<String>()
  var cancelled = false
  var producerCancelled = false
  var readReceipt: Receipt?
  var commitReceipt: Receipt?
  var readInterrupted = false
  var outcome: Outcome = .prepared
  var author = 1_779_996_400
  var committed = 1_779_992_800
  var readAt = 1_780_000_000
  var hash = String(repeating: "a", count: 40)
  var stalePreview = false
  var receipt: Receipt { Receipt(generation: generation, days: days, forget: forgetRevision) }
  var cutoff: Int { max(now, maintained) - days * 86400 }
  func historical(_ time: Int) -> Bool {
    guard let latest = history.enumerated().filter({ $0.element.time <= time }).max(by: {
      ($0.element.time, $0.offset) < ($1.element.time, $1.offset)
    })?.element else { return false }
    return latest.enabled && (latest.pause ?? Int.min) <= time
  }
  func forgotten(_ time: Int) -> Bool { forgotten.contains { $0.contains(time) } }
  var current: Bool { secure == false && enabled && (pause ?? Int.min) <= now && historical(now) && !forgotten(now) }
  var provenance: Bool { !linked.subtracting(revoked).isEmpty }
  var nativePrivacy: Bool { forgotten(author) || forgotten(committed) || !historical(author) || !historical(committed) }
  var expired: Bool { author < cutoff || committed < cutoff }
  var commitAllowed: Bool {
    current && provenance && !cancelled && !producerCancelled && commitReceipt == receipt && !nativePrivacy && !expired && !erased.contains(hash)
  }
  var frontierAllowed: Bool {
    current && provenance && !cancelled && !producerCancelled && readReceipt == receipt && readAt >= cutoff && !readInterrupted
  }
  func discoveryAllowed(_ source: Int) -> Bool {
    let time = now - 100
    return current && !cancelled && !revoked.contains(source) && historical(time) && !forgotten(time) && time >= cutoff
  }
  mutating func settings(enabled: Bool, pause: Int?, at time: Int) {
    if self.enabled != enabled || self.pause != pause {
      history.append(History(time: time, enabled: enabled, pause: pause)); generation += 1
    }
    self.enabled = enabled; self.pause = pause
  }
}

// SplitMix64 makes every schedule independent of Swift's randomized Hasher.
struct GitScheduleRandom {
  var state: UInt64
  mutating func next(_ upper: Int) -> Int {
    state &+= 0x9e3779b97f4a7c15
    var value = state
    value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
    value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
    return Int((value ^ (value >> 31)) % UInt64(upper))
  }
}

enum GitScheduleEvent: String, CaseIterable {
  case secureOn, secureUnknown, secureOff, recordingOff, recordingOn, roundTrip, pause, resume
  case authorOff, commitOff, authorPause, commitPause, own, revoke, retain, expand, preview, forget, staleConfirm
  case cancel, replacement, stop, crash, brokenStream, busy
}

enum GitScheduleStep: Equatable, CustomStringConvertible {
  case discover(Int), prepare, parent, file(Int), ref, complete, stage, certify
  case event(GitScheduleEvent), arm(String, GitScheduleEvent), retime, retry
  var description: String {
    switch self {
    case .discover(let n): return "discover(\(n))"
    case .prepare: return "prepare"
    case .parent: return "parent"
    case .file(let n): return "file(\(n))"
    case .ref: return "ref"
    case .complete: return "complete"
    case .stage: return "stage"
    case .certify: return "certify"
    case .event(let event): return event.rawValue
    case .arm(let phase, let event): return "after(\(phase),\(event.rawValue))"
    case .retime: return "retime"
    case .retry: return "retry"
    }
  }
}

struct GitScheduleViolation: Error, CustomStringConvertible {
  let property: String
  let detail: String
  var description: String { "\(property): \(detail)" }
}

// Delta debugging preserves the failing property, then single-deletion checks
// establish a 1-minimal trace. It never claims globally shortest traces.
func shrinkGitSchedule(_ input: [GitScheduleStep], fails: ([GitScheduleStep]) throws -> Bool) rethrows -> [GitScheduleStep] {
  var result = input, width = max(1, input.count / 2)
  while width > 0 {
    var offset = 0
    while offset < result.count {
      var candidate = result
      candidate.removeSubrange(offset..<min(offset + width, result.count))
      if try fails(candidate) { result = candidate } else { offset += width }
    }
    width /= 2
  }
  return result
}

// Different bytes across chunk boundaries make reordering visible to the oracle.
func gitSchedulePayload(_ byte: UInt8, count: Int) -> Data {
  var result = Data()
  for offset in stride(from: 0, to: count, by: 65536) {
    result.append(Data(repeating: byte + UInt8((offset / 65536) % 7), count: min(65536, count - offset)))
  }
  return result
}

// Shrinking must preserve the producer contract. Otherwise deleting all child
// reads could make a truthful completion look broken on the original code too.
func gitScheduleIsReplayable(_ schedule: [GitScheduleStep]) -> Bool {
  var observed = false, prepared = false, parent = false, staged = false, malformed = false
  var files = Set<Int>(), reachedRef = false
  for step in schedule {
    switch step {
    case .discover: observed = true
    case .prepare:
      guard observed else { return false }; prepared = true
    case .parent:
      guard prepared else { return false }; parent = true; files = []; reachedRef = false
    case .file(let index):
      guard parent else { return false }; files.insert(index)
    case .ref:
      guard parent else { return false }; reachedRef = true
    case .complete:
      guard parent, (files == [0, 1] && reachedRef) || (malformed && !files.isEmpty) else { return false }
    case .stage:
      guard parent else { return false }; staged = true
    case .certify:
      guard staged else { return false }
    case .retry, .event(.crash):
      prepared = false; parent = false; staged = false; malformed = false; files = []; reachedRef = false
    case .event(.brokenStream): malformed = true
    case .event, .arm, .retime: break
    }
  }
  return true
}
