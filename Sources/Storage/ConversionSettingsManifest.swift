import Core
import CryptoKit
import Foundation

extension ActivityStorage {
  /// Read-only validation of the effective legacy choices. The import marker prevents reimport;
  /// a later changed legacy file makes the operator audit fail instead of changing the destination.
  public func conversionSettingsManifest(privacyFile: URL, generalFile: URL, pauseUntilFile: URL,
    pauseKeptFile: URL, recordingIntent: Bool, approvedDirectory: OperationalDirectory? = nil) throws -> [ConversionManifestLine] {
    let types = ConversionManifestLine(metric: "settings.invalid_integer_values", expected: 0,
      actual: try locked { try connection.invalidIntegerValues() })
    guard types.passed else { return [types] }
    func read(_ file: URL) throws -> Data? {
      if let approvedDirectory { return try approvedDirectory.read(file.lastPathComponent) }
      return try OperationalDirectory.read(file)
    }
    var expected = StorageSettings()
    expected.recordingEnabled = recordingIntent
    var readable = false
    if let bytes = try read(privacyFile), let old = try? JSONDecoder().decode(OldPrivacy.self, from: bytes) {
      readable = true
      expected.excludedApps = Array(Set(old.apps.map { $0.lowercased() })).sorted()
      expected.pausedUntil = old.pausedUntil
      expected.screenRetentionDays = max(1, min(old.retentionDays ?? 30, 36500))
      expected.promptRetentionDays = expected.screenRetentionDays
    }
    func note(_ file: URL) throws -> Int? {
      try read(file).flatMap { Int(String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    expected.pausedUntil = [expected.pausedUntil, try note(pauseUntilFile),
      try oldPauseKeptApplies(privacyFile: privacyFile, decoded: readable, directory: approvedDirectory) ? try note(pauseKeptFile) : nil].compactMap { $0 }.max()
    if let bytes = try read(generalFile), let old = try? JSONDecoder().decode(OldGeneral.self, from: bytes) {
      if let language = old.outputLanguage { expected.general["outputLanguage"] = language }
      if let hour = old.dayStartHour, (0...23).contains(hour) { expected.general["dayStartHour"] = String(hour) }
    }
    let actual = try settings()
    func digest(_ text: String) -> Int {
      SHA256.hash(data: Data(text.utf8)).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    }
    func settingsNumbers(_ settings: StorageSettings, masked: Bool) -> [String: Int] {
      let apps = settings.excludedApps.map { masked ? Redaction.applyKnownSecrets($0).text : $0 }.sorted()
      let language = settings.general["outputLanguage"] ?? ""
      return ["recording_intent": settings.recordingEnabled ? 1 : 0, "paused_until": settings.pausedUntil ?? 0,
        "pause_present": settings.pausedUntil == nil ? 0 : 1, "excluded_apps": apps.count,
        "excluded_identity_digest": digest(apps.joined(separator:"\n")), "screen_retention": settings.screenRetentionDays,
        "prompt_retention": settings.promptRetentionDays, "output_language_digest": digest(masked ? Redaction.apply(language).text : language),
        "day_start": settings.dayStartHour,
        "subscription_connected": settings.subscriptionConnected ? 1 : 0]
    }
    let desired = settingsNumbers(expected, masked: true), found = settingsNumbers(actual, masked: false)
    var lines = [types] + desired.keys.sorted().map { ConversionManifestLine(metric:"settings." + $0,expected:desired[$0]!,actual:found[$0]!) }
    // Audit persisted bytes independently of the forgiving settings decoder. Chat safety,
    // connection consent and generations must remain absent, as in a pristine adoption.
    var expectedPairs = ["initialized":"1", "old-files-imported":"1", "recording":recordingIntent ? "1":"0",
      "retention.screen":String(expected.screenRetentionDays), "retention.prompt":String(expected.promptRetentionDays)]
    if let pause = expected.pausedUntil { expectedPairs["pause"] = String(pause) }
    for (index, app) in Set(expected.excludedApps.map { $0.lowercased() }).sorted().enumerated() {
      expectedPairs["app.\(index)"] = Redaction.applyKnownSecrets(app).text
    }
    for (key, value) in expected.general { expectedPairs["general." + key] = Redaction.apply(value).text }
    func hex(_ text: String) -> String { text.utf8.map { String(format:"%02X",$0) }.joined() }
    let expectedBytes = Dictionary(uniqueKeysWithValues:expectedPairs.map { (hex($0.key),hex($0.value)) })
    let expectedNames = Dictionary(uniqueKeysWithValues:expectedPairs.keys.map { (hex($0),$0) })
    var actualBytes: [String:String] = [:], actualNames: [String:String] = [:]
    try locked {
      // Compare raw bytes so UTF-8 repair cannot hide a changed persisted value.
      try connection.namedRows("SELECT key,hex(key) AS key_bytes,hex(value) AS value_bytes FROM settings ORDER BY key") {
        let key = try $0.text("key_bytes")
        actualBytes[key] = try $0.text("value_bytes")
        actualNames[key] = try $0.text("key")
      }
      lines.append(ConversionManifestLine(metric:"settings.invalid_text_values",expected:0,
        actual:try connection.integer("SELECT count(*) FROM settings WHERE typeof(key)!='text' OR typeof(value)!='text'")))
    }
    lines.append(ConversionManifestLine(metric:"settings.unique_rows",expected:expectedPairs.count,
      actual:try locked { try connection.integer("SELECT count(*) FROM settings") }))
    func canonical(_ pairs: [String:String]) throws -> Data {
      try JSONSerialization.data(withJSONObject:pairs.keys.sorted().map { [$0,pairs[$0]!] })
    }
    let expectedHash = Array(SHA256.hash(data:try canonical(expectedBytes)))
    let actualHash = Array(SHA256.hash(data:try canonical(actualBytes)))
    for word in 0..<8 {
      func number(_ bytes: [UInt8]) -> Int { bytes[(word * 4)..<(word * 4 + 4)].reduce(0) { ($0 << 8) | Int($1) } }
      lines.append(ConversionManifestLine(metric:"settings.digest.\(word)",expected:number(expectedHash),actual:number(actualHash)))
    }
    let mismatches = Set(expectedBytes.keys).union(actualBytes.keys).filter {
      expectedBytes[$0] != actualBytes[$0]
    }.sorted()
    lines.append(ConversionManifestLine(metric:"settings.mismatched_keys",expected:0,actual:mismatches.count))
    for key in mismatches {
      // Escape names onto one line; never include settings values in operator output.
      let name = String(decoding:try JSONEncoder().encode(Redaction.apply(expectedNames[key] ?? actualNames[key] ?? "").text),as:UTF8.self)
      lines.append(ConversionManifestLine(metric:"settings.mismatch." + name,expected:0,actual:1))
    }
    let historyRows = expected.recordingEnabled && expected.pausedUntil == nil ? 1 : 2
    lines.append(ConversionManifestLine(metric:"settings.history_rows",expected:historyRows,actual:try logRecordingHistory().count))
    // Adoption starts with the pristine schema snapshot, then the effective imported state.
    var desiredHistory: [(Int, Int, Int?)] = [(Int.min, 1, nil)]
    if historyRows == 2 { desiredHistory.append((Int.min, expected.recordingEnabled ? 1 : 0, expected.pausedUntil)) }
    var index = 0
    try locked {
      try connection.namedRows("SELECT id,since,enabled,CAST(paused_until AS TEXT) AS pause FROM log_recording_history ORDER BY id") { row in
        defer { index += 1 }
        guard index < desiredHistory.count else { return }
        let desired = desiredHistory[index], pause = try row.optionalText("pause").flatMap(Int.init)
        let values: [(String, Int, Int)] = [
          ("order", index + 1, try row.int("id")), ("since", desired.0, try row.int("since")),
          ("enabled", desired.1, try row.int("enabled")), ("pause_present", desired.2 == nil ? 0 : 1, pause == nil ? 0 : 1),
          ("paused_until", desired.2 ?? 0, pause ?? 0)]
        for (field, wanted, found) in values {
          lines.append(ConversionManifestLine(metric: "settings.history.\(index)." + field, expected: wanted, actual: found))
        }
      }
    }
    return lines
  }
}
