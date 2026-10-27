import Core
import Foundation
import Storage

extension ActivityStorage {
  // Invented fixture consent follows the same transitions as a successful app connection.
  func saveFixtureSettings(_ value: StorageSettings, at time: Int = Int(Date().timeIntervalSince1970)) throws {
    try saveSettings(value, at: time)
    if value.subscriptionConnected {
      let pending = try patchSettings(.beginConnection)
      _ = try patchSettings(.completeConnection(generation: pending.connectionGeneration))
    } else {
      _ = try patchSettings(.disconnect)
    }
    // Summaries follow Claude use, which has its own connection transaction.
    if value.claudeConnected {
      let pending = try patchSettings(.beginClaudeConnection)
      _ = try patchSettings(.completeClaudeConnection(generation: pending.claudeConnectionGeneration))
    } else if try settings().claudeConnected {
      _ = try patchSettings(.disconnectClaude)
    }
  }
}

extension StorageSettings {
  /// The same settings with Claude use on, which summaries need.
  var withClaudeUse: StorageSettings {
    var value = self; value.general["chat.claude.connected"] = "1"; return value
  }
}

extension StorageSettings {
  /// Claude use, which gates summaries, as a plain switch for invented settings.
  var claudeUse: Bool {
    get { claudeConnected }
    set { general["chat.claude.connected"] = newValue ? "1" : nil }
  }
}
