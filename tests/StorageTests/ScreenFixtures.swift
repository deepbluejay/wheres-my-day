import Core
import Storage

extension ActivityStorage {
  @discardableResult func appendFixtureEvidence(_ rows: [EvidenceText]) throws -> AppendResult {
    var total = AppendResult()
    for row in rows {
      let result: AppendResult
      if row.kind == .screen {
        result = try appendScreenCapture(text: row.text, at: row.ts, source: row.source,
          documentKey: row.documentKey, project: row.project, knownKeys: []).append
      } else {
        result = try appendEvidence([row])
      }
      total.stored += result.stored
      total.refused += result.refused
    }
    return total
  }
}
