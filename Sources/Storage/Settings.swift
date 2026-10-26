import Core
import Darwin
import Foundation

extension ActivityStorage {
  public func settings() throws -> StorageSettings {
    try locked {
      var result = StorageSettings()
      var apps: [String] = []
      var appLabels: [String: String] = [:], appIdentities: [String: String] = [:]
      var initialized = false
      try connection.namedRows("SELECT key,value FROM settings ORDER BY key") {
        let key = try $0.text("key")
        let value = try $0.text("value")
        switch key {
        case "initialized": initialized = true
        case "subscription.generation": result.connectionGeneration = value
        case "subscription.connected": result.subscriptionConnected = value == "1"
        case "recording": result.recordingEnabled = value != "0"
        case "pause": result.pausedUntil = Int(value)
        case "retention.screen": result.screenRetentionDays = Int(value) ?? 30
        case "retention.prompt": result.promptRetentionDays = Int(value) ?? 30
        default:
          if key.hasPrefix("app.") { apps.append(value); appLabels[String(key.dropFirst(4))] = value }
          if key.hasPrefix("appIdentity.") { appIdentities[String(key.dropFirst(12))] = value }
          if key.hasPrefix("general.") { result.general[String(key.dropFirst(8))] = value }
        }
      }
      if initialized {
        result.excludedApps = Array(Set(apps)).sorted()
        for (index, identity) in appIdentities {
          if let label = appLabels[index] { result.excludedAppPrivacyIdentities[label, default: []].insert(identity) }
        }
      }
      return result
    }
  }
  func writeSettings(_ settings: StorageSettings, probeEdit: Bool = false) throws {
    try SettingsValidation.validate(settings)
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    guard settings.general.keys.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
      throw StorageError("General settings keys accept only A-Z, a-z, 0-9, dot, underscore and hyphen")
    }
    let probeProtected = probeEdit ? "" : ",'general.axProbe.run','general.axProbe.enabled','general.axProbe.reviewActive','general.axProbe.reviewGeneration','general.axProbe.reviewLease'"
    try connection.run("DELETE FROM settings WHERE key NOT IN ('old-files-imported','subscription.generation','subscription.connected','general.chat.claude.generation','general.chat.claude.connected','summary.serviceUnavailableUntil'\(probeProtected))")
    var pairs: [(String, String)] = [
      ("initialized", "1"), ("recording", settings.recordingEnabled ? "1" : "0"),
      ("retention.screen", String(settings.screenRetentionDays)),
      ("retention.prompt", String(settings.promptRetentionDays)),
    ]
    if let pause = settings.pausedUntil { pairs.append(("pause", String(pause))) }
    for (index, app) in settings.persistedAppExclusions.enumerated() {
      pairs.append(("app.\(index)", app.label))
      if app.identity != ApplicationPrivacyIdentity.digest(app.label) {
        pairs.append(("appIdentity.\(index)", app.identity))
      }
    }
    // Consent and its generation belong to connection transactions, never caller snapshots.
    for (key, value) in settings.general where !["chat.claude.generation", "chat.claude.connected"].contains(key) {
      if !probeEdit && ["axProbe.run", "axProbe.enabled", "axProbe.reviewActive", "axProbe.reviewGeneration", "axProbe.reviewLease"].contains(key) { continue }
      pairs.append(("general." + key, value))
    }
    for (key, value) in pairs {
      // An exclusion must keep matching its OS identity after a settings round trip.
      let stored: SQLValue = (key.hasPrefix("app.") || key == "general.chat.selection")
        ? .maskedText(Redaction.applyKnownSecrets(value).text) : .text(value)
      try connection.run("INSERT INTO settings(key,value) VALUES(?,?)", [.key(key), stored])
    }
  }
  public func saveSettings(_ settings: StorageSettings) throws {
    try saveSettings(settings, at: Int(Date().timeIntervalSince1970))
  }

  /// The settings screen uses wall time; invented tests supply their own transition time.
  public func saveSettings(_ settings: StorageSettings, at time: Int) throws {
    try locked {
      try connection.transaction {
        try writeSettings(settings)
        try recordLogPrivacy(settings, at: time)
      }
    }
  }
  public func patchSettings(_ patch: SettingsPatch) throws -> StorageSettings {
    try locked {
      try connection.transaction {
        var latest = try settings()
        var time = Int(Date().timeIntervalSince1970)
        switch patch {
        case .resolveTimelineNotices(let health):
          latest = TimelineNotices.resolved(settings: latest, health: health) ?? latest
        case .chatSkipApprovals(let enabled): latest.general["chat.skipApprovals"] = enabled ? "1" : "0"
        case .beginClaudeConnection, .disconnectClaude:
          try writeConsent(false, prefix: "general.chat.claude", generation: UUID().uuidString)
        case .completeClaudeConnection(let generation):
          guard latest.claudeConnectionGeneration == generation else { throw SettingsValidationError.connectionSuperseded }
          try writeConsent(true, prefix: "general.chat.claude")
        case .chatSelection(let selection):
          guard selection.isValid else { throw ActivityQueryError.invalidArguments }
          latest.general["chat.selection"] = String(decoding: try JSONEncoder().encode(selection), as: UTF8.self)
        case .edit(let edit, let ownBundleID, let now):
          time = now
          latest = try SettingsViewModel(settings: latest, health: TimelineHealth(), ownBundleID: ownBundleID, now: now).applying(edit)
        case .beginConnection, .disconnect:
          // A fresh token also invalidates attempts begun before an already-disconnected revocation.
          try writeConsent(false, prefix: "subscription", generation: UUID().uuidString)
        case .completeConnection(let generation):
          guard latest.connectionGeneration == generation else { throw SettingsValidationError.connectionSuperseded }
          try writeConsent(true, prefix: "subscription")
        }
        try writeSettings(latest)
        try recordLogPrivacy(latest, at: time)
        return try settings()
      }
    }
  }
  private func writeConsent(_ connected: Bool, prefix: String, generation: String? = nil) throws {
    try connection.run("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)",
      [.key(prefix + ".connected"), .text(connected ? "1" : "0")])
    if let generation {
      try connection.run("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)", [.key(prefix + ".generation"), .key(generation)])
    }
  }
  private func recordLogPrivacy(_ settings: StorageSettings, at time: Int) throws {
    var latest: LogRecordingState?
    try connection.namedRows("""
      SELECT since,enabled,CAST(paused_until AS TEXT) AS paused_until
      FROM log_recording_history ORDER BY id DESC LIMIT 1
      """) {
      latest = LogRecordingState(
        since: try $0.int("since"), enabled: try $0.int("enabled") != 0,
        pausedUntil: try $0.optionalText("paused_until").flatMap(Int.init))
    }
    if let latest, latest.enabled == settings.recordingEnabled, latest.pausedUntil == settings.pausedUntil { return }
    try connection.run(
      "INSERT INTO log_recording_history(since,enabled,paused_until) VALUES(?,?,?)",
      [.integer(time), .integer(settings.recordingEnabled ? 1 : 0),
       settings.pausedUntil.map(SQLValue.integer) ?? .null])
  }
  // Called within appendLogBatch's transaction, so privacy transitions and positions cannot race.
  func logRecordingAllowed(at time: Int) throws -> Bool {
    var allowed = true
    try connection.namedRows(
      """
      SELECT enabled,CAST(paused_until AS TEXT) AS paused_until FROM log_recording_history
      WHERE since<=? ORDER BY since DESC,id DESC LIMIT 1
      """,
      [.integer(time)]
    ) {
      let pause = try $0.optionalText("paused_until").flatMap(Int.init)
      allowed = try $0.int("enabled") != 0 && (pause ?? Int.min) <= time
    }
    return allowed
  }
  public func logRecordingHistory() throws -> [LogRecordingState] {
    try locked {
      var result: [LogRecordingState] = []
      try connection.namedRows("""
        SELECT since,enabled,CAST(paused_until AS TEXT) AS paused_until FROM log_recording_history ORDER BY since,id
        """) {
        result.append(LogRecordingState(
          since: try $0.int("since"), enabled: try $0.int("enabled") != 0,
          pausedUntil: try $0.optionalText("paused_until").flatMap(Int.init)))
      }
      return result
    }
  }

  /// Import after the database conversion, never before.
  /// Explicit invented-file paths in tests; the switch passes the old paths once. No source writes.
  @discardableResult public func importOldSettings(privacyFile: URL, generalFile: URL,
    pauseUntilFile: URL? = nil, pauseKeptFile: URL? = nil, recordingIntent: Bool? = nil, approvedDirectory: OperationalDirectory? = nil) throws -> Bool {
    func read(_ file: URL) throws -> Data? {
      if let approvedDirectory { return try approvedDirectory.read(file.lastPathComponent) }
      return try OperationalDirectory.read(file)
    }
    return try locked {
      try connection.transaction {
        guard try connection.integer("SELECT count(*) FROM settings WHERE key='old-files-imported'") == 0 else {
          return false
        }
        // Only the converter's recording intent may precede adoption. Keep existing choices
        // and damaged adoption markers intact so the operator audit can report the mismatch.
        guard try connection.integer("SELECT count(*) FROM settings WHERE key!='recording'") == 0 else { return false }
        // A person who has already changed the DB settings wins over a delayed import.
        if try connection.integer("SELECT count(*) FROM settings WHERE key='initialized'") == 0 {
          var settings = try self.settings()
          var privacyReadable = false
          if let data = try read(privacyFile),
            let old = try? JSONDecoder().decode(OldPrivacy.self, from: data)
          {
            privacyReadable = true
            settings.excludedApps = Array(Set(old.apps.map { $0.lowercased() })).sorted()
            settings.pausedUntil = old.pausedUntil
            let days = max(1, min(old.retentionDays ?? 30, 36500))
            settings.screenRetentionDays = days
            settings.promptRetentionDays = days
          }
          func note(_ file: URL?) throws -> Int? {
            guard let file, let bytes = try read(file) else { return nil }
            return Int(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
          }
          settings.pausedUntil = [settings.pausedUntil, try note(pauseUntilFile),
            try oldPauseKeptApplies(privacyFile: privacyFile, decoded: privacyReadable, directory: approvedDirectory) ? try note(pauseKeptFile) : nil]
            .compactMap { $0 }.max()
          if let recordingIntent { settings.recordingEnabled = recordingIntent }
          if let data = try read(generalFile),
            let old = try? JSONDecoder().decode(OldGeneral.self, from: data)
          {
            if let language = old.outputLanguage { settings.general["outputLanguage"] = language }
            if let hour = old.dayStartHour, (0...23).contains(hour) { settings.general["dayStartHour"] = String(hour) }
          }
          try writeSettings(settings)
          // No old transition times exist. Adopt the imported privacy snapshot, as for a version-1 DB.
          try recordLogPrivacy(settings, at: Int.min)
        }
        try connection.run("INSERT INTO settings(key,value) VALUES('old-files-imported','1')")
        return true
      }
    }
  }
}

// A missing privacy file has defaults; only a present unreadable file uses the recorder's kept pause.
func oldPauseKeptApplies(privacyFile: URL, decoded: Bool, directory: OperationalDirectory? = nil) throws -> Bool {
  guard !decoded else { return false }
  if let directory { return try directory.exists(privacyFile.lastPathComponent) }
  var info = stat()
  return lstat(privacyFile.path, &info) == 0 || errno != ENOENT
}

struct OldPrivacy: Decodable {
  var apps: [String]
  var pausedUntil: Int?
  var retentionDays: Int?
  private enum CodingKeys: String, CodingKey { case apps, autoContextProjects, pausedUntil, retentionDays }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    apps = try values.decodeIfPresent([String].self, forKey: .apps) ?? []
    // Its value is retired, but a wrong type made the legacy file unreadable.
    _ = try values.decodeIfPresent([String].self, forKey: .autoContextProjects)
    pausedUntil = try values.decodeIfPresent(Int.self, forKey: .pausedUntil)
    if let whole = try? values.decodeIfPresent(Int.self, forKey: .retentionDays) {
      retentionDays = whole
    } else {
      retentionDays = try values.decodeIfPresent(Double.self, forKey: .retentionDays).map {
        Int(max(1, min($0, 36500)))
      }
    }
  }
}

struct OldGeneral: Decodable {
  var outputLanguage: String?
  var dayStartHour: Int?
  private enum CodingKeys: String, CodingKey { case outputLanguage, dayStartHour }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    outputLanguage = try? values.decode(String.self, forKey: .outputLanguage)
    dayStartHour = try? values.decode(Int.self, forKey: .dayStartHour)
  }
}
