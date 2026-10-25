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
  }
}
