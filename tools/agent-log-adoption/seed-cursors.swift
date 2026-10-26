import Core
import CryptoKit
import Darwin
import Foundation
@testable import Storage

let base = URL(fileURLWithPath: CommandLine.arguments[1])
func json(_ object: Any) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}
// Main already collapsed recognized-credential paths at SQL binding. Seed those
// independently; only main's recoverable distinct cursors can promise no replay.
let shapes = [["invented-a", "invented-\\u0061"],
  ["invented-sk-proj-" + String(repeating: "v", count: 48)],
  ["invented-sk-proj-" + String(repeating: "w", count: 48)],
  ["invented-\\u0073k-proj-" + String(repeating: "v", count: 48)],
  ["invented-\\u0073k-proj-" + String(repeating: "w", count: 48)]]
var fixtures: [[String: Any]] = []
for tool in AgentLogTool.allCases {
  for stems in shapes {
    for partialRecovery in [false, true] {
      for reverse in [false, true] {
        let folder = base.appendingPathComponent("cursor-\(fixtures.count)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let storage = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"),
          appDataDirectory: folder, databaseScope: .directory(folder))
        try storage.saveSettings(StorageSettings(), at: 0)
        var names: [String] = []
        for (i, stem) in stems.enumerated() {
          let name = stem + ".jsonl", session = "invented-session-\(i)"
          names.append(name)
          let url = folder.appendingPathComponent(name)
          let header = try json(tool == .claude ? ["type": "system", "sessionId": session]
            : ["type": "session_meta", "payload": ["id": session]])
          let record = try json(tool == .claude
            ? ["type": "user", "sessionId": session, "uuid": "invented-item-\(i)",
              "timestamp": "1970-01-01T00:03:20Z", "message": ["role": "user", "content": "Invented cursor instruction"]]
            : ["type": "event_msg", "timestamp": "1970-01-01T00:03:20Z", "payload": [
              "type": "item_completed", "thread_id": session, "turn_id": "invented-turn",
              "item": ["id": "invented-item-\(i)", "type": "UserMessage",
                "content": [["type": "text", "text": "Invented cursor instruction"]]]]])
          var lines = [header]
          if partialRecovery { lines.append(try json(["type": "invented-padding", "value": String(repeating: "x", count: 2 << 20)])) }
          lines.append(record)
          let text = lines.joined(separator: "\n") + "\n"
          try Data(text.utf8).write(to: url)
          var state = AgentLogState()
          for line in lines {
            if case .prompt(let evidence) = AgentLogParser.parse(line, tool: tool, file: url.path, state: &state,
              fingerprint: { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }) {
              try storage.appendEvidence([evidence])
            }
          }
          var info = stat(); precondition(stat(url.path, &info) == 0)
          try storage.saveLogPosition(LogPosition(path: url.path, device: Int(info.st_dev), inode: Int(info.st_ino),
            offset: text.utf8.count, state: try state.encoded(), seenAt: 299))
          let saved = try storage.logPosition(path: url.path)
          precondition(saved?.offset == text.utf8.count)
        }
        fixtures.append(["folder": folder.lastPathComponent, "tool": tool.rawValue,
          "names": reverse ? Array(names.reversed()) : names, "partial": partialRecovery])
      }
    }
  }
}
try JSONSerialization.data(withJSONObject: fixtures).write(to: base.appendingPathComponent("cursor-cases.json"))
print("Actual-main cursor seed: \(fixtures.count) fixtures, 48 EOF checkpoints and historical prompts")
