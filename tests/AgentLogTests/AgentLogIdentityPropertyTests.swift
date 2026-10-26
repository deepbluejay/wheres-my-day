@testable import Core
@testable import Inbound
@testable import Storage
import Foundation
import XCTest

extension AgentLogTests {
  func testGeneratedDecodedBytesHaveOneKeyAcrossEveryPathWithoutMerging() throws {
    for seed in logPropertySeeds {
      var random = LogTraceRandom(state: seed)
      let trace = random.shuffle(logIdentityCorpus + logIdentityCorpus)
      try checkLogTrace(seed: seed, trace: trace.map { Data($0.utf8) }) { subjects in
        var keys: [Data: Data] = [:], reverse: [Data: Data] = [:]
        var typed: [Data: AgentLogNativeComponent] = [:]
        let registry = AgentLogFiles.ownSources(appDataDirectory: self.root)
        try self.store.connection.run("CREATE TEMP TABLE IF NOT EXISTS property_identity(key TEXT PRIMARY KEY)")
        try self.store.connection.run("DELETE FROM property_identity")
        for bytes in subjects {
          let raw = String(decoding: bytes, as: UTF8.self)
          let input = AgentLogIdentity.decoded(bytes)
          var incremental = AgentLogIdentity.decoded([UInt8]())
          for byte in bytes { incremental.consume(byte) }
          let native = input.component
          let encoded = try JSONEncoder().encode(native)
          let decoded = try JSONDecoder().decode(AgentLogNativeComponent.self, from: encoded)
          let paths = [native.storedKey, incremental.component.storedKey, decoded.storedKey]
          if Set(paths.map { Data($0.utf8) }).count != 1 { return "constructor/codec paths disagree" }
          let key = Data(native.storedKey.utf8)
          for (otherBytes, other) in typed where (native == other) != (bytes == otherBytes) {
            return "typed equality disagrees with decoded byte equality"
          }
          typed[bytes] = native
          try self.store.connection.run("INSERT OR IGNORE INTO property_identity VALUES(?)", [.key(native)])
          let physical = AgentLogIdentity.decoded(bytes, domain: .physicalSource).physicalSource
          if physical != AgentLogIdentity.decodedPath(raw) { return "physical source paths disagree" }
          if let old = keys[bytes], old != key { return "same decoded bytes changed key" }
          if let old = reverse[key], old != bytes { return "distinct decoded bytes merged" }
          keys[bytes] = key; reverse[key] = bytes
          // An opaque native component may be blank; session usability is a separate contract.
          if let subject = input.session.subject {
            try registry.registerSession(subject, tool: .claude)
            if try !registry.containsSession(subject, tool: .claude) { return "launch receipt changed subject" }
            let text = try self.json(["type": "system", "sessionId": raw])
            var state = AgentLogState()
            _ = AgentLogEventParser.parse(Data(text.utf8), byteCount: text.utf8.count, offset: 0, observedAt: 200,
              tool: .claude, file: "/invented/property.jsonl", state: &state, logsRelativePath: nil,
              fingerprint: AgentLogFiles.fingerprint)
            guard state.session == subject else { return "full parser changed decoded subject" }
            let restored = try AgentLogState.decode(state.encoded())
            guard restored.session == subject else { return "checkpoint changed subject" }
            var scanner = AgentLogMetadata()
            for byte in text.utf8 { scanner.consume(byte) }
            guard scanner.explicitSession(tool: .claude) == subject else { return "scanner changed subject" }
          }
        }
        if try self.store.connection.integer("SELECT count(*) FROM property_identity") != Set(subjects).count {
          return "SQL key equality differs from decoded byte equality"
        }
        return nil
      }
    }
  }

  func testGeneratedSessionTransitionsIgnoreRoleChunkingAndRestart() throws {
    struct Step: CustomStringConvertible {
      let kind: Int, subject: Int, role: Int, chunk: Int, restart: Bool
      var description: String { "(kind=\(kind),subject=\(subject),role=\(role),chunk=\(chunk),restart=\(restart))" }
    }
    let subjects = ["invented-é", "invented-e\u{301}", "invented-b"]
    for tool in AgentLogTool.allCases {
      for seed in logPropertySeeds {
        var random = LogTraceRandom(state: seed)
        var trace = (0..<30).map { _ in Step(kind: random.next(5), subject: random.next(3), role: random.next(4),
          chunk: [1, 7, 64, 4096][random.next(4)], restart: random.next(2) == 0) }
        trace += [Step(kind: 0, subject: 0, role: 0, chunk: 1, restart: true),
          Step(kind: 4, subject: 0, role: 3, chunk: 7, restart: true),
          Step(kind: 2, subject: 2, role: 1, chunk: 64, restart: true)]
        try checkLogTrace(seed: seed, trace: trace) { steps in
          var eventState = AgentLogState(), projectionState = AgentLogState(), replayState = AgentLogState()
          var expected: Data?, owned: Data?
          for step in steps {
            let raw = subjects[step.subject]
            let role = ["user", "assistant", "tool", "system"][step.role]
            var fields: [String: Any] = ["type": role]
            var payload: [String: Any] = [:]
            switch step.kind {
            case 0, 4:
              if tool == .claude { fields["sessionId"] = raw }
              else { fields["type"] = "session_meta"; payload["id"] = raw }
              expected = Data(raw.utf8)
            case 1: // Missing Claude metadata inherits; a missing Codex header clears it.
              if tool == .codex { fields["type"] = "session_meta"; expected = nil }
            case 2:
              if tool == .claude { fields["sessionId"] = NSNull() }
              else { fields["type"] = "session_meta"; payload["id"] = NSNull() }
              expected = nil
            default: // Explicit event thread is attribution, not a replacement header.
              if tool == .codex { payload["thread_id"] = raw }
            }
            if step.kind == 4 {
              fields["cwd"] = "/invented/" + AgentWindowIdentity.relativeFolder
              payload["cwd"] = fields["cwd"]
              owned = expected
            }
            if tool == .codex { fields["payload"] = payload }
            let text = try self.json(fields), bytes = Array(text.utf8)
            var scanner = AgentLogMetadata()
            for start in stride(from: 0, to: bytes.count, by: step.chunk) {
              for byte in bytes[start..<min(start + step.chunk, bytes.count)] { scanner.consume(byte) }
              if step.restart && scanner.checkpointSafe {
                scanner = try JSONDecoder().decode(AgentLogMetadata.self, from: JSONEncoder().encode(scanner))
              }
            }
            _ = AgentLogEventParser.parse(Data(bytes), byteCount: bytes.count, offset: 0, observedAt: 200,
              tool: tool, file: "/invented/property.jsonl", state: &eventState, logsRelativePath: nil,
              fingerprint: AgentLogFiles.fingerprint)
            _ = AgentLogParser.parse(text, tool: tool, file: "/invented/property.jsonl", state: &projectionState,
              fingerprint: AgentLogFiles.fingerprint)
            scanner.apply(tool: tool, file: "/invented/property.jsonl", state: &replayState, fingerprint: AgentLogFiles.fingerprint)
            for state in [eventState, projectionState, replayState] {
              if state.session.map({ Data($0.storedKey.utf8) }) != expected { return "header inheritance differs from byte model for \(tool)" }
              if state.ownedSession.map({ Data($0.storedKey.utf8) }) != owned { return "positive ownership differs from byte model for \(tool)" }
            }
            if step.restart {
              eventState = try AgentLogState.decode(eventState.encoded())
              projectionState = try AgentLogState.decode(projectionState.encoded())
              replayState = try AgentLogState.decode(replayState.encoded())
            }
          }
          return nil
        }
      }
    }
  }
}
