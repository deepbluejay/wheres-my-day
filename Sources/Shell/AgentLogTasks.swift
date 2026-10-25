import Core
import Foundation
import Inbound
import Storage

public enum AgentLogErrorKind: String { case busy, storage, files, state, process }
public struct AgentLogHealth {
  public var lastSuccessTime: Int?
  public var lastErrorKind: AgentLogErrorKind?
  public var stored = 0
  public var refused = 0
  public var malformedLines = 0
  public var failures = 0
  public var fileFailures = 0
  public var folderFailures = 0
  public var ignored: [AgentLogIgnore: Int] = [:]
}

/// Scan runs on the maintenance queue. The lock makes health readable from the shell's main thread.
public final class AgentLogTask {
  private let reader: AgentLogReader
  let storage: AgentLogStorage
  private let lock = NSLock()
  private var status = AgentLogHealth()
  /// Besides consent, log reading waits for a ChatGPT sign-in with plan use, because the evidence is
  /// read only to be summarized. Set once by the composition, before maintenance starts.
  var planUseSignedIn: () -> Bool = { true }
  public init(reader: AgentLogReader, storage: AgentLogStorage) {
    self.reader = reader
    self.storage = storage
  }
  public var health: AgentLogHealth {
    lock.lock()
    defer { lock.unlock() }
    return status
  }
  public var maintenanceTask: RecorderMaintenanceTask {
    RecorderMaintenanceTask(name: reader.name) { time in try self.scan(at: time) }
  }
  // Runs off the recorder's main thread with a separate client storage object.
  public func scan(at time: Int) throws {
    let listing: AgentLogListing
    do {
      guard try storage.settings().subscriptionConnected, planUseSignedIn() else { return }
      listing = try reader.listing()
    } catch {
      recordFailure(error)
      throw error
    }
    var failure: Error?
    if listing.folderFailures > 0 {
      lock.lock()
      status.folderFailures += listing.folderFailures
      lock.unlock()
      for _ in 0..<listing.folderFailures { recordFailure(AgentLogReadError.fileUnavailable) }
      failure = AgentLogReadError.fileUnavailable
    }
    for file in listing.files {
      do {
        var position = try storage.logPosition(path: file.path)
        while true {
          guard try storage.settings().subscriptionConnected else { return }
          let batch = try reader.read(file, position: position, at: time)
          guard try storage.settings().subscriptionConnected else { return }
          let result = try storage.appendLogBatch(batch.evidence, position: batch.position)
          lock.lock()
          status.stored += result.stored
          status.refused += result.refused
          status.malformedLines += batch.malformedLines
          for (reason, count) in batch.ignored { status.ignored[reason, default: 0] += count }
          lock.unlock()
          if batch.position.offset >= file.size || batch.position.offset == position?.offset { break }
          // An unfinished final line is left until the next scan.
          if batch.position.offset == 0 { break }
          position = batch.position
        }
      } catch {
        recordFailure(error)
        lock.lock()
        status.fileFailures += 1
        lock.unlock()
        failure = error
      }
    }
    if let failure { throw failure }
    lock.lock()
    status.lastSuccessTime = time
    status.lastErrorKind = nil
    lock.unlock()
  }
  private func recordFailure(_ error: Error) {
    lock.lock()
    defer { lock.unlock() }
    status.failures += 1
    switch error {
    case StorageError.busy: status.lastErrorKind = .busy
    case AgentLogReadError.invalidState: status.lastErrorKind = .state
    case AgentLogReadError.processUnavailable: status.lastErrorKind = .process
    case is AgentLogReadError: status.lastErrorKind = .files
    default: status.lastErrorKind = .storage
    }
  }
}

/// The later process switch owns these connections and passes both to RecorderLoop, then calls stop before release.
public final class RecorderConnections {
  public let recorder: ActivityStorage
  public let client: ActivityStorage
  public let logTasks: [AgentLogTask]
  public let securityTask: SecurityHealthTask
  public private(set) var summaryTask: SummaryTask?
  public init(database: URL, appDataDirectory: URL, userHome: String, processes: AgentLogProcessSource, summaryCodexHome: URL? = nil,
    fileVault: FileVaultStatusSource = FileVaultReader(), databaseScope: DatabaseOpenScope) throws {
    recorder = try ActivityStorage(url: database, appDataDirectory: appDataDirectory, role: .recorder, databaseScope: databaseScope)
    // Retention/log batches must not hold the recorder object's in-process lock and delay a tick.
    client = try ActivityStorage(url: database, appDataDirectory: appDataDirectory, role: .client, databaseScope: databaseScope)
    securityTask = SecurityHealthTask(fileVault: fileVault, storage: recorder.securityHealth)
    logTasks = Self.makeLogTasks(database: client, appDataDirectory: appDataDirectory, userHome: userHome,
      processes: processes, summaryCodexHome: summaryCodexHome)
  }
  init(recorder: ActivityStorage, client: ActivityStorage, logTasks: [AgentLogTask], fileVault: FileVaultStatusSource) {
    self.recorder = recorder; self.client = client; self.logTasks = logTasks
    securityTask = SecurityHealthTask(fileVault: fileVault, storage: recorder.securityHealth)
  }
  static func makeLogTasks(database: ActivityStorage, appDataDirectory: URL, userHome: String,
    processes: AgentLogProcessSource, summaryCodexHome: URL?) -> [AgentLogTask] {
    [
      AgentLogTask(reader: ClaudeAgentLogReader(userHome: userHome, processes: processes, appDataDirectory: appDataDirectory), storage: database),
      AgentLogTask(reader: CodexAgentLogReader(userHome: userHome, processes: processes, summaryCodexHome: summaryCodexHome, appDataDirectory: appDataDirectory), storage: database),
    ]
  }
  public func configureSummary(caller: SummaryCaller, from start: Int,
    dayStart: @escaping (Int) -> Int, locale: @escaping () -> String) throws {
    guard summaryTask == nil else { throw RecorderStartupError.summaryAlreadyConfigured }
    try client.saveSummaryUnavailableUntil(nil)
    summaryTask = SummaryTask(storage: client, caller: caller, from: start, dayStart: dayStart, locale: locale, publish: client.saveSummaryUnavailableUntil)
  }
  public var maintenanceTasks: [RecorderMaintenanceTask] {
    logTasks.map(\.maintenanceTask) + [securityTask.maintenanceTask] + (summaryTask.map { [$0.maintenanceTask] } ?? [])
  }
  public func makeLoop(
    clock: RecorderClock, input: InputCountSource, front: FrontWindowSource,
    secure: SecureInputSource, awake: DisplayAwakeSource, screen: ScreenTextSource, ownBundleID: String
  ) -> RecorderLoop {
    RecorderLoop(
      clock: clock, input: input, front: front, secure: secure, awake: awake, screen: screen,
      storage: recorder, maintenanceStorage: client, ownBundleID: ownBundleID, maintenanceTasks: maintenanceTasks)
  }
}
