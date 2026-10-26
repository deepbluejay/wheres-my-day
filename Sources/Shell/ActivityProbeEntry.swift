import Core
import Darwin
import Foundation
import Inbound
import Outbound
import Storage

public enum ActivityProbeEntry {
  /// Production and isolated routes share the same database-open boundary and composition.
  public static func run(arguments: [String], environment: [String: String], userHome: URL, appBinary: URL) -> Int32 {
    if arguments.first == "launch-agent" {
      let result = LaunchAgentCommand.run(Array(arguments.dropFirst()), userHome: userHome)
      if !result.output.isEmpty { print(result.output) }; return result.status
    }
    if arguments.first == "convert" {
      let result = ConversionCommand.run(Array(arguments.dropFirst()), userHome: userHome, appBinary: appBinary)
      print(result.output); return result.status
    }
    if arguments == ["privacy", "mask"] {
      let result = RetainedCommands.mask(FileHandle.standardInput.readDataToEndOfFile())
      if !result.output.isEmpty { print(result.output) }; return result.status
    }
    if arguments.first != "collect" {
      do {
        let parsed = try command(arguments: arguments, environment: environment, userHome: userHome, appBinary: appBinary)
        if ProcessPresentation.mode(arguments: parsed.arguments) == .dock {
          let reopen = parsed.arguments == AppWindowReopen.arguments
          let target = reopen ? .timeline : AppWindowTarget(arguments: parsed.arguments)
          return AppWindowEntry.run(paths: parsed.paths, target: target, reopen: reopen,
            codex: .installed("codex", environment: environment, home: userHome.path),
            claude: .installed("claude", environment: environment, home: userHome.path), environment: environment, isolated: arguments.contains("--isolated-root"))
        }
        let input = parsed.arguments == ["privacy", "verdicts"] ? FileHandle.standardInput.readDataToEndOfFile() : Data()
        let applications = parsed.arguments == ["privacy", "verdicts"] ? try RetainedCommands.applicationIdentities(paths: parsed.paths) : []
        let result = RetainedCommands.run(parsed.arguments, paths: parsed.paths, input: input, applications: applications)
        if !result.output.isEmpty { print(result.output) }; return result.status
      } catch { print("entry_arguments_refused"); return 2 }
    }
    let configuration: IsolatedRecorderConfiguration
    do {
      configuration = try recorderConfiguration(arguments: arguments, environment: environment,
        userHome: userHome, appBinary: appBinary)
    } catch {
      print("entry_arguments_refused"); return 2
    }
    let paths = configuration.paths
    do {
      let guardOwner = try RecorderStartupGuard(paths: paths)
      let composition = configuration.composition()
      // A login launch after a deliberate stop exits before constructing any Mac adapters.
      let enabled = try composition.recordingEnabledAtStartup()
      let launchesWindow = !configuration.isolated && !TestPathGuard.active
      if launchesWindow {
        try RecorderWindowLauncher.launch(paths: paths, target: nil, environment: environment)
      }
      guard enabled else { return 0 }
      let clock = WallRecorderClock()
      // The real adapters are constructed here only after isolation and startup validation.
      let connections = try composition.recorder(processes: configuration.isolated ? NoAgentLogProcesses() : MacAgentLogProcessSource(), fileVault: FileVaultReader(),
        from: 0, dayStart: { time in
          let settings = try? connectionsDayStart(paths: paths)
          return (try? TimelineDay.range(containing: time, dayStartHour: settings ?? TimelineDay.defaultDayStartHour, calendar: .current).start) ?? time
        }, locale: {
          (try? composition.queryStorage().settings().general["outputLanguage"]) ?? Locale.current.identifier
        }, recorderLock: guardOwner.recorderLock)
      let input = MacInputSource()
      let loop = connections.makeLoop(clock: clock, input: input, front: MacFrontWindowSource(),
        secure: MacSecureInputSource(), awake: MacDisplayAwakeSource(), screen: MacScreenTextSource(), ownBundleID: AppPaths.bundleID)
      let lifecycle = RecorderLifecycle(loop: loop, clock: clock, startInput: { _ = input.start() },
        stopInput: input.stop, observeSession: { MacRecorderSessionObserver(receive: $0) },
        initialSnapshot: MacRecorderSessionObserver.snapshot, requestSummary: { connections.summaryTask?.request(through: $0) })
      // An open of the app starts the window process the same way as the menu at startup;
      // a running window process gets the request from that launch instead.
      // Isolated and test recorders never launch a window, so they never take opens either.
      let events = MainActor.assumeIsolated {
        RecorderEventLoop(open: launchesWindow ? {
          try? RecorderWindowLauncher.launch(paths: paths, arguments: AppWindowReopen.arguments, environment: environment)
        } : nil)
      }
      // A session-end quit takes the same stop and, like every stop, exits 0.
      let stop: () -> Void = { [weak lifecycle] in
        lifecycle?.stop { health in
          print("stopped stored=\(health.storedSeconds) dropped_seconds=\(health.droppedSeconds) dropped_captures=\(health.droppedCaptures) pending_seconds=\(health.pendingSeconds) pending_captures=\(health.pendingCaptures) stored_ocr_bytes=\(health.storedOCRBytes) stored_observations=\(health.storedObservations) pending_observations=\(health.pendingObservations) dropped_observations=\(health.droppedObservations) collection_failures=\(health.collectionFailures) collection_backpressure=\(health.collectionBackpressure) collection_busy_retries=\(health.collectionBusyRetries) collection_acquisition_failures=\(health.collectionAcquisitionFailures) collection_staging_failures=\(health.collectionStagingFailures) collection_persistence_failures=\(health.collectionPersistenceFailures) collection_initialization_failures=\(health.collectionInitializationFailures) collection_retained_bytes=\(health.collectionRetainedBytes) collection_diagnostic_publication_failures=\(health.collectionDiagnosticPublicationFailures) collection_evicted_loss_receipts=\(health.collectionEvictedLossReceipts)")
          MainActor.assumeIsolated { events.stop() }
        }
      }
      loop.recordingDisabled = stop
      MainActor.assumeIsolated { events.endSession = stop }
      signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
      let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler(handler: stop)
        source.resume(); return source
      }
      try guardOwner.publish()
      lifecycle.start()
      withExtendedLifetime((guardOwner, connections, lifecycle, signals)) { MainActor.assumeIsolated { events.run() } }
      // run returns only after the stop's drain; the lock and pid file go with guardOwner.
      return 0
    } catch { print("recorder_start_refused"); return 1 }
  }
  public static func command(arguments: [String], environment: [String: String], userHome: URL,
    appBinary: URL) throws -> (arguments: [String], paths: AppPaths) {
    if arguments.contains("--isolated-root") || arguments.contains("--app-data") {
      return try isolatedCommand(arguments: arguments, environment: environment, userHome: userHome, appBinary: appBinary)
    }
    guard !["selftest", "leaktest"].contains(arguments.first ?? ""),
      !arguments.contains("--live-switch") else { throw IsolatedEntryError.arguments }
    return (arguments, try AppPaths.resolve(userHome: userHome, environment: environment, appBinary: appBinary))
  }
  public static func recorderConfiguration(arguments: [String], environment: [String: String], userHome: URL,
    appBinary: URL) throws -> IsolatedRecorderConfiguration {
    if arguments.contains("--isolated-root") || arguments.contains("--app-data") {
      return try isolatedConfiguration(arguments: arguments, environment: environment, excludedUserHome: userHome, appBinary: appBinary)
    }
    guard arguments == ["collect"] else { throw IsolatedEntryError.arguments }
    return IsolatedRecorderConfiguration(paths: try AppPaths.resolve(userHome: userHome, environment: environment, appBinary: appBinary),
      isolated: false)
  }
  public static func isolatedCommand(arguments: [String], environment: [String: String], userHome: URL,
    appBinary: URL) throws -> (arguments: [String], paths: AppPaths) {
    var remaining: [String] = [], root: String?, data: String?, index = 0
    while index < arguments.count {
      if ["--isolated-root", "--app-data"].contains(arguments[index]) {
        guard index + 1 < arguments.count else { throw IsolatedEntryError.arguments }
        if arguments[index] == "--isolated-root" { guard root == nil else { throw IsolatedEntryError.arguments }; root = arguments[index + 1] }
        else { guard data == nil else { throw IsolatedEntryError.arguments }; data = arguments[index + 1] }
        index += 2
      } else { remaining.append(arguments[index]); index += 1 }
    }
    guard let root, let data else { throw IsolatedEntryError.arguments }
    let configuration = try isolatedConfiguration(arguments: ["collect", "--isolated-root", root, "--app-data", data],
      environment: environment, excludedUserHome: userHome, appBinary: appBinary)
    return (remaining, configuration.paths)
  }
  // Validation is pure path work, so tests never have to construct a Mac source.
  public static func isolatedConfiguration(arguments: [String], environment: [String: String],
    excludedUserHome: URL, appBinary: URL) throws -> IsolatedRecorderConfiguration {
    guard arguments.count == 5, arguments[0] == "collect", arguments[1] == "--isolated-root",
      arguments[3] == "--app-data" else {
      throw IsolatedEntryError.arguments
    }
    try FileLocation.validate(excludedUserHome)
    try FileLocation.validate(arguments[2])
    try FileLocation.validate(arguments[4])
    let root = try CanonicalPath.resolve(URL(fileURLWithPath: arguments[2]))
    let data = try CanonicalPath.resolve(URL(fileURLWithPath: arguments[4]))
    guard let override = environment["ACTIVITYPROBE_DB"], !override.isEmpty else { throw IsolatedEntryError.paths }
    try FileLocation.validate(override)
    let requested = URL(fileURLWithPath: override)
    let database = try CanonicalPath.resolve(requested.deletingLastPathComponent()).appendingPathComponent(requested.lastPathComponent)
    // This reserved path is only an exclusion, never a default runtime context.
    let realData = try CanonicalPath.resolve(excludedUserHome.appendingPathComponent("Library/Application Support/ActivityProbe"))
    let temporary = try CanonicalPath.resolve(URL(fileURLWithPath: "/tmp"))
    guard try FileLocation.contains(root, in: temporary, includingRoot: false, granting: true),
      try FileLocation.contains(data, in: root, includingRoot: false, granting: true),
      try !FileLocation.contains(root, in: realData), try !FileLocation.contains(data, in: realData) else {
      throw IsolatedEntryError.paths
    }
    let scope = DatabaseOpenScope.directory(root, excluding: [realData])
    try scope.validatePath(database)
    let paths = AppPaths(userHome: root.appendingPathComponent("source-home"), appData: data, database: database,
      appBinary: appBinary, queryHelper: appBinary.deletingLastPathComponent().appendingPathComponent("ActivityQueryServer"), databaseScope: scope)
    return IsolatedRecorderConfiguration(paths: paths)
  }
  private static func connectionsDayStart(paths: AppPaths) throws -> Int {
    let settings = try AppComposition(paths: paths).queryStorage().settings()
    return settings.dayStartHour
  }
}

public enum IsolatedEntryError: Error { case arguments, paths }

public struct IsolatedRecorderConfiguration {
  public let paths: AppPaths
  public var isolated = true
  public init(paths: AppPaths, isolated: Bool = true) { self.paths = paths; self.isolated = isolated }
  // Isolated mode has no passive readers or process-home discovery. App-owned home exclusions
  // in the readers remain independent and are exercised by their own invented-file suites.
  /// An isolated recorder never reads the person's Keychain: its token port is an empty, never signed-in
  /// account, so its summaries stay paused.
  public func composition(factories: AppFactories = AppFactories()) -> AppComposition {
    var factories = factories
    if isolated {
      factories.chatGPTTokens = { _ in
        ChatGPTSession(store: InMemoryChatGPTCredentialStore(), lock: ChatGPTCredentialLock(file: nil), openBrowser: { _ in false })
      }
    }
    return AppComposition(paths: paths, factories: factories, includesPassiveLogs: !isolated)
  }
}
