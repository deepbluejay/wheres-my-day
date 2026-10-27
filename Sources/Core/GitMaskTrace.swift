import Foundation

extension AgentLogEventParser {
  static func gitSafeString(_ text: String, depth: Int) -> String { sanitizedString(text, depth: depth) }
  static func gitValueDepthRefused(_ depth: Int) -> Bool { depth >= 12 }
  struct GitJSONMaskPosition {
    let path: [String]
    let ranges: [NSRange]?
  }
  private final class GitJSONTrace {
    var positions: [GitJSONMaskPosition] = []
  }
  private static let gitJSONTraceKey = "ActivityProbe.inventedGitJSONTrace"
  static var gitTracingJSON: Bool { Thread.current.threadDictionary[gitJSONTraceKey] != nil }
  static func gitTraceJSON(_ input: String) -> (String, [GitJSONMaskPosition]) {
    let trace = GitJSONTrace()
    Thread.current.threadDictionary[gitJSONTraceKey] = trace
    defer { Thread.current.threadDictionary.removeObject(forKey: gitJSONTraceKey) }
    return (Redaction.apply(safeString(input)).text, trace.positions)
  }
  static func gitTraceValue(_ path: [String]?) {
    guard let path, let trace = Thread.current.threadDictionary[gitJSONTraceKey] as? GitJSONTrace else { return }
    trace.positions.append(GitJSONMaskPosition(path: path, ranges: nil))
  }
  static func gitTraceString(_ value: String, depth: Int, identity: Bool, path: [String]?) -> String {
    guard let path, let trace = Thread.current.threadDictionary[gitJSONTraceKey] as? GitJSONTrace else {
      return sanitizedString(value, depth: depth, identity: identity)
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if depth >= 12 || value.contains("\\u") || ["{", "[", "\""].contains(where: { trimmed.hasPrefix($0) }) {
      // Nested encoded JSON has no direct source-token correspondence.
      let previous = Thread.current.threadDictionary[gitJSONTraceKey]
      Thread.current.threadDictionary.removeObject(forKey: gitJSONTraceKey)
      let result = sanitizedString(value, depth: depth, identity: identity)
      Thread.current.threadDictionary[gitJSONTraceKey] = previous
      if result != value && result.contains(Redaction.secretMark) { gitTraceValue(path) }
      return result
    }
    var result = ""
    let (_, ranges) = Redaction.gitTracePlain(value) {
      result = sanitizedString(value, depth: depth, identity: identity)
      return identity ? result : Redaction.apply(result).text
    }
    trace.positions.append(GitJSONMaskPosition(path: path, ranges: ranges))
    return result
  }
}
