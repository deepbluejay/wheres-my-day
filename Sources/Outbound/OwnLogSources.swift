import Core
import CryptoKit
import Foundation

enum OwnLogSources {
  static func registry(appDataDirectory: URL) -> AgentLogOwnSources {
    AgentLogOwnSources(appDataDirectory: appDataDirectory, digest: {
      SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
    })
  }
}
