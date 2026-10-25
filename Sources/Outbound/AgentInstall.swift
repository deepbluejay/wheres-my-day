import Core
import CoreServices
import Foundation
import Security

/// Where an agent's CLI was found, and the PATH its own children need. A CLI a version manager
/// installed is a script whose interpreter sits beside it on the search path it was found on.
public struct AgentInstall: Equatable {
  public enum Origin: String, Equatable { case path, native, homebrew, desktopApp, fixed }
  public let executable: URL
  public let origin: Origin
  /// nil keeps the PATH the caller was given (an executable named explicitly, never looked up).
  public let childPath: String?
  public init(executable: URL, origin: Origin, childPath: String?) {
    self.executable = executable; self.origin = origin; self.childPath = childPath
  }
  /// The child environment with only PATH replaced; every other allow-listed value stays as given.
  public func environment(_ base: [String: String]) -> [String: String] {
    guard let childPath else { return base }
    var values = base; values["PATH"] = childPath; return values
  }

  /// The search order every caller shares, so an install is never found by one and missed by
  /// another: the person's shell path (this process's when it did not answer), the native
  /// installer's folder, Homebrew's two prefixes, and for Codex the CLI in the ChatGPT desktop app.
  static let desktopAppIdentifiers = ["com.openai.codex", "com.openai.chat"]
  /// The team in the desktop app's signature. If the vendor signs with another team, its CLI is
  /// not found until this changes.
  static let desktopAppTeam = "2DC432GLL2"
  /// Test seams. The defaults ask Launch Services and the Security framework, which need no
  /// application object, so the background recorder may use them.
  static var desktopApps: () -> [URL] = {
    TestPathGuard.active ? [] : desktopAppIdentifiers.flatMap { identifier -> [URL] in
      (LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil)?.takeRetainedValue() as? [URL]) ?? []
    }
  }
  static var signedByVendor: (URL) -> Bool = { validSignature($0, team: desktopAppTeam) }
  static var homebrew = "/opt/homebrew/bin:/usr/local/bin"

  private static let lock = NSLock()
  private static var pinned: [String: AgentInstall] = [:]
  /// A later install becomes visible. Only tests use it.
  static func forget() { lock.lock(); pinned = [:]; lock.unlock() }

  /// The base search path, then the fallbacks. Relative or empty entries never make the working
  /// directory a source of executables.
  static func childPath(base: String, home: String?) -> String {
    let native = home.map { URL(fileURLWithPath: $0).appendingPathComponent(".local/bin").path }
    let entries = ([base] + [native].compactMap { $0 } + [homebrew]).joined(separator: ":")
      .split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    var seen = Set<String>()
    return entries.filter { seen.insert($0).inserted }.joined(separator: ":")
  }

  static func executable(in searchPath: String, name: String) -> URL? {
    for directory in searchPath.split(separator: ":") where directory.hasPrefix("/") {
      let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
      if runnable(url) { return url }
    }
    return nil
  }

  static func runnable(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
      && FileManager.default.isExecutableFile(atPath: url.path)
  }

  /// `shellPath` is the person's shell answer, or nil when it did not answer.
  static func find(_ name: String, shellPath: String?, environment: [String: String], home: String?) -> AgentInstall? {
    let base = shellPath ?? environment["PATH"] ?? "/usr/bin:/bin"
    let native = home.map { URL(fileURLWithPath: $0).appendingPathComponent(".local/bin").path }
    let key = [name, base, native ?? ""].joined(separator: "\n")
    lock.lock(); let kept = pinned[key]; lock.unlock()
    // One operation never runs two installs: a found CLI stays the answer while it is still there.
    if let kept, runnable(kept.executable) { return kept }
    let path = childPath(base: base, home: home)
    var found: AgentInstall?
    let places = [(base, Origin.path)] + (native.map { [($0, Origin.native)] } ?? []) + [(homebrew, .homebrew)]
    for (directories, origin) in places {
      if let url = executable(in: directories, name: name) { found = AgentInstall(executable: url, origin: origin, childPath: path); break }
    }
    if found == nil, name == "codex", let url = desktopApps().lazy.compactMap(bundledCodex(in:)).first {
      found = AgentInstall(executable: url, origin: .desktopApp, childPath: path)
    }
    lock.lock(); pinned[key] = found; lock.unlock()
    return found
  }

  /// The one layout known for the desktop app's CLI. An app laid out otherwise, or one that only
  /// claims the identifier, has no CLI here. A failed check is not remembered, so a repaired app
  /// is seen at the next lookup.
  static func bundledCodex(in app: URL) -> URL? {
    let url = app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
    guard runnable(url), signedByVendor(app) else { return nil }
    return url
  }

  /// A valid signature with nested code and resources, on a certificate Apple issued to `team`.
  static func validSignature(_ app: URL, team: String) -> Bool {
    guard !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString, [], &requirement) == errSecSuccess,
      let requirement else { return false }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
  }
}

/// A CLI as callers hold it: looked up only when a child is about to start, off the main thread,
/// so neither the window nor the recorder's sampling waits for the person's shell.
public struct AgentExecutable {
  public let name: String
  private let locate: () -> AgentInstall?
  private let claudeConfig: () -> String?
  private let claudeKnown: () -> Bool
  init(name: String, claudeConfigDirectory: @escaping () -> String? = { nil }, claudeConfigKnown: @escaping () -> Bool = { true },
    locate: @escaping () -> AgentInstall?) {
    self.name = name; self.locate = locate; claudeConfig = claudeConfigDirectory; claudeKnown = claudeConfigKnown
  }
  /// nil means not installed: nothing is started.
  public func resolve() -> AgentInstall? { locate() }
  /// The CLAUDE_CONFIG_DIR the person's terminal has, or nil to leave the CLI on its default.
  /// Like resolve(), it may wait for the person's shell, so it is called off the main thread.
  public func claudeConfigDirectory() -> String? { claudeConfig() }
  /// False when the terminal may use another Claude folder than the app's children: the shell did not
  /// answer, or named a relative one.
  public func claudeConfigKnown() -> Bool { claudeKnown() }

  /// Searched the way the person's terminal would find it.
  public static func installed(_ name: String, environment: [String: String], home: String?) -> AgentExecutable {
    AgentExecutable(name: name, claudeConfigDirectory: { UserShell.claudeConfigDirectory(environment: environment) },
      claudeConfigKnown: { UserShell.claudeConfigKnown(environment: environment) }) {
      AgentInstall.find(name, shellPath: UserShell.path(environment: environment), environment: environment, home: home)
    }
  }
  /// An executable named explicitly. It is used as given, with the caller's PATH and no config folder.
  public static func fixed(_ url: URL) -> AgentExecutable {
    AgentExecutable(name: url.lastPathComponent) { AgentInstall(executable: url, origin: .fixed, childPath: nil) }
  }
}
