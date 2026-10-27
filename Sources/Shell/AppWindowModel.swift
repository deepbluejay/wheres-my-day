import Core
import Foundation
import Outbound
import Storage
import SwiftUI

public enum AppWindowTarget: Equatable {
  case timeline, conversation, settings(SettingsSection)
  public init?(arguments: [String]) {
    switch arguments {
    case [], ["timeline"]: self = .timeline
    case ["agent-window"]: self = .conversation
    case ["settings"]: self = .settings(.recording)
    default:
      guard arguments.count == 2, arguments[0] == "settings", let section = SettingsSection(rawValue: arguments[1]) else { return nil }
      self = .settings(section)
    }
  }
  var line: String {
    switch self {
    case .timeline: return "timeline"
    case .conversation: return "agent-window"
    case .settings(let section): return "settings " + section.rawValue
    }
  }
  init?(line: String) {
    let arguments = line.split(separator: " ").map(String.init)
    guard !arguments.isEmpty else { return nil }
    self.init(arguments: arguments)
  }
}

/// Width is a per-window preference. Shrinking the window clamps its display, not the preference.
public struct AppWindowLayout {
  public static let minimumTimeline = 360.0
  public static let minimumPanel = 360.0
  public static let divider = 9.0
  public static let minimumWidth = minimumTimeline + minimumPanel + divider
  public private(set) var preferredPanel = 400.0
  public init() {}
  public func panelWidth(in width: Double) -> Double {
    min(max(Self.minimumPanel, preferredPanel), max(Self.minimumPanel, width - Self.minimumTimeline - Self.divider))
  }
  public mutating func choosePanelWidth(_ value: Double, in width: Double) {
    guard value.isFinite, width.isFinite else { return }
    preferredPanel = min(max(Self.minimumPanel, value), max(Self.minimumPanel, width - Self.minimumTimeline - Self.divider))
  }
}

public struct AppWindowSnapshot {
  public let day: TimelineDay
  public let health: TimelineHealth
  public let dayStartHour: Int
  public let now: Int
  public init(day: TimelineDay, health: TimelineHealth, dayStartHour: Int = 4, now: Int = Int(Date().timeIntervalSince1970)) {
    self.day = day; self.health = health; self.dayStartHour = dayStartHour; self.now = now
  }
}

@MainActor public final class AppWindowModel: ObservableObject {
  public let settings: SettingsController
  @Published public private(set) var settingsVisible = false
  @Published public private(set) var panelOpen = false
  @Published public private(set) var layout = AppWindowLayout()
  @Published public private(set) var conversation: ConversationController?
  @Published public private(set) var snapshot: AppWindowSnapshot?
  @Published public private(set) var readFailed = false
  public private(set) var closed = false
  private let makeConversation: () throws -> ConversationController
  @Published public private(set) var selectedDate: Date?
  private var selectionRevision = 0
  private let read: (Date?) async throws -> AppWindowSnapshot
  private let readMonth: (Date) async throws -> Set<Date>
  private var refreshTask: Task<Void, Never>?
  private var conversationTask: Task<Void, Never>?
  private var reading = false
  public init(settings: SettingsController, makeConversation: @escaping () throws -> ConversationController,
    read: @escaping () async throws -> AppWindowSnapshot) {
    self.settings = settings; self.makeConversation = makeConversation; self.read = { _ in try await read() }
    self.readMonth = { _ in [] }
  }
  public init(settings: SettingsController, makeConversation: @escaping () throws -> ConversationController,
    readDay: @escaping (Date?) async throws -> AppWindowSnapshot, readMonth: @escaping (Date) async throws -> Set<Date>) {
    self.settings = settings; self.makeConversation = makeConversation; self.read = readDay; self.readMonth = readMonth
  }
  public func recordedDays(in month: Date) async throws -> Set<Date> { try await readMonth(month) }
  public func chooseDay(_ date: Date, calendar: Calendar = .current) {
    guard let snapshot, !closed else { return }
    let navigation = TimelineDayNavigation(day: snapshot.day.range, now: snapshot.now,
      dayStartHour: snapshot.dayStartHour, calendar: calendar)
    guard navigation.canSelect(date) else { return }
    selectedDate = calendar.isDate(date, inSameDayAs: navigation.today) ? nil : calendar.startOfDay(for: date)
    selectionRevision += 1
    Task { await refresh() }
  }
  public func stepDay(_ amount: Int, calendar: Calendar = .current) {
    guard let snapshot else { return }
    let navigation = TimelineDayNavigation(day: snapshot.day.range, now: snapshot.now,
      dayStartHour: snapshot.dayStartHour, calendar: calendar)
    // nil means following today, including while an older day's read is still displayed.
    guard let date = calendar.date(byAdding: .day, value: amount, to: selectedDate ?? navigation.today) else { return }
    chooseDay(date, calendar: calendar)
  }
  public func showToday() { selectedDate = nil; selectionRevision += 1; Task { await refresh() } }
  deinit { refreshTask?.cancel(); conversationTask?.cancel() }
  public func navigate(_ target: AppWindowTarget) {
    guard !closed else { return }
    switch target {
    case .timeline: settingsVisible = false
    case .conversation: settingsVisible = false; openConversation()
    case .settings(let section): settings.section = section; settings.refresh(); settingsVisible = true
    }
  }
  public func route(_ notice: TimelineNoticeKind) { navigate(.settings(notice.settingsSection)) }
  public func back() { navigate(.timeline) }
  public func toggleConversation() { if panelOpen { closePanel() } else { openConversation() } }
  public func openConversation() {
    guard !closed else { return }
    if conversation == nil {
      do { conversation = try makeConversation() }
      catch { readFailed = true; return }
    }
    panelOpen = true
  }
  public func closePanel() { panelOpen = false }
  public func choosePanelWidth(_ width: Double, available: Double) { layout.choosePanelWidth(width, in: available) }
  public func start() {
    guard !closed, refreshTask == nil else { return }
    refreshTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
  }
  public func refresh() async {
    guard !closed, !reading else { return }
    reading = true
    defer { reading = false }
    do {
      // A selection made during a slow read wins; never publish a stale day over it.
      var revision: Int
      var value: AppWindowSnapshot
      repeat {
        revision = selectionRevision
        value = try await read(selectedDate)
        guard !closed, !Task.isCancelled else { return }
      } while revision != selectionRevision
      snapshot = value; settings.health = value.health; settings.refresh(); readFailed = false
    } catch { if !closed { readFailed = true } }
  }
  /// A hidden panel still checks consent and approval deadlines. Catalog work starts only on open.
  public func startConversationObservation() {
    guard !closed, let conversation, conversationTask == nil else { return }
    conversationTask = Task { [weak conversation] in
      guard !Task.isCancelled else { return }
      await conversation?.loadCatalog()
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let conversation else { return }
        let connected = conversation.connected
        conversation.refresh()
        if connected != conversation.connected { await conversation.loadCatalog() }
      }
    }
  }
  public func close() {
    guard !closed else { return }
    closed = true; refreshTask?.cancel(); refreshTask = nil
    conversationTask?.cancel(); conversationTask = nil; conversation?.stop()
    settings.cancelConnection(); settings.cancelClaudeConnection()
    panelOpen = false
  }
}

public extension AppComposition {
  /// Settings is obtained first, with both sign-in sources, before any child controller is constructed.
  @MainActor func windowModel(codex: AgentExecutable, claude: AgentExecutable,
    health: @escaping () -> TimelineHealth, statusReader: ChatGPTStatusReader? = nil) throws -> (AppWindowModel, ActivityStorage) {
    let settings = try settings(claude: claude)
    let edits = try factories.storage(paths, .client, nil)
    let composition = self
    let chatGPT = statusReader ?? ChatGPTStatusReader(account: factories.chatGPT(paths))
    let conversationTokens = factories.chatGPTTokens(paths)
    let model = AppWindowModel(settings: settings, makeConversation: {
      try ConversationController(store: edits) { selection, skip in
        let configuration = composition.conversation(command: selection.provider == .codex ? codex : claude, skipApprovals: skip)
        return composition.factories.conversationAgent(selection.provider, configuration, conversationTokens)
      }
    }, readDay: { selectedDate in
      try await Task.detached {
        let store = try composition.queryStorage()
        let now = Int(Date().timeIntervalSince1970)
        var current = health()
        current.chatGPT = chatGPT.status()
        var displayed = current
        var dayStartHour = TimelineDay.defaultDayStartHour
        let day = try store.withQuerySnapshot {
          let saved = try store.settings()
          dayStartHour = saved.dayStartHour
          let shown = try selectedDate.map { try TimelineDay.range(on: $0, dayStartHour: saved.dayStartHour, calendar: .current).start } ?? now
          if current.summary != nil { current.summary?.subscriptionConnected = saved.claudeConnected }
          if let until = try store.summaryUnavailableUntil(), until > Double(now) {
            if current.summary == nil { current.summary = SummaryHealth() }
            current.summary?.subscriptionConnected = saved.claudeConnected
            current.summary?.serviceUnavailableUntil = until
            current.summary?.planUsePaused = true
          }
          displayed = current
          do {
            let range = try TimelineDay.range(containing: shown, dayStartHour: saved.dayStartHour, calendar: .current)
            let failures = SummaryHealth.unresolvedFailedRanges(in: try store.modelCalls(overlapping: range))
            var summary = displayed.summary ?? SummaryHealth(); summary.subscriptionConnected = saved.claudeConnected
            summary.failedRanges = failures; displayed.summary = summary
          }
          return try TimelineDay.read(containing: shown, now: now, calendar: .current, storage: store, health: displayed)
        }
        // Resolve against the latest settings inside the patch transaction, preserving concurrent edits.
        if try TimelineNotices.resolved(settings: store.settings(), health: current) != nil {
          _ = try edits.patchSettings(.resolveTimelineNotices(current))
        }
        return AppWindowSnapshot(day: day, health: displayed, dayStartHour: dayStartHour, now: now)
      }.value
    }, readMonth: { month in
      try await Task.detached {
        let store = try composition.queryStorage()
        return try store.withQuerySnapshot {
          try TimelineDay.recordedDays(inMonth: month, dayStartHour: store.settings().dayStartHour,
            calendar: .current, storage: store)
        }
      }.value
    })
    return (model, edits)
  }
}

/// The ChatGPT status for the timeline's notice. It reads the Keychain, so it runs on the window's
/// background read, never on the main thread or the recorder's sampling, and at most once per `interval`.
public final class ChatGPTStatusReader {
  static let interval: TimeInterval = 30
  private let account: ChatGPTAccount
  private let clock: () -> TimeInterval
  private let lock = NSLock()
  private var last: (at: TimeInterval, status: ChatGPTConnectionStatus)?
  init(account: ChatGPTAccount, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.account = account; self.clock = clock
  }
  func status() -> ChatGPTConnectionStatus {
    lock.lock(); defer { lock.unlock() }
    let now = clock()
    if let last, now - last.at < Self.interval { return last.status }
    let status = account.status()
    last = (now, status)
    return status
  }
}
