import Core
import Foundation

extension ActivityStorage {
  /// Only a record's own identity can disambiguate a lossy historical label.
  public func applicationPrivacyRefusedSeconds(_ samples: [TimeSample], settings: StorageSettings, ownBundleID: String) throws -> Set<Int> {
    let historical = HistoricalApplicationPrivacy(applications: settings.excludedApps + [ownBundleID])
    let own = ApplicationPrivacyIdentity.digest(ownBundleID)
    return Set(samples.filter { sample in
      if sample.excluded { return true }
      if let identity = sample.applicationPrivacyIdentity {
        return identity == own || settings.excludesApplication(sample.bundleID, identity: identity)
      }
      return historical.contains(sample.bundleID)
    }.map(\.ts))
  }
}
