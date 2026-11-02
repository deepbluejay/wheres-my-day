import Core
import Foundation
import Outbound
import Storage
import SwiftUI

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
  /// `now` reaches the screen only through the day navigation's "today", which changes on a minute at the finest.
  func looksTheSame(as other: AppWindowSnapshot) -> Bool {
    dayStartHour == other.dayStartHour && TimelineDay.floorMinute(now) == TimelineDay.floorMinute(other.now)
      && health == other.health && day == other.day
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
  private var refreshAgain = false
  /// Set by the host from the window's occlusion. False only slows the loop: a report can be wrong or missed,
  /// and removed data must not then stay on a window someone can see.
  private(set) var windowVisible = true
  /// The pace on screen, which also bounds how long removed data can stay there. A test may shorten it.
  var refreshInterval: Duration = .seconds(1)
  /// The pace while hidden, and so the longest a wrong occlusion value can leave removed data on screen.
  var hiddenRefreshInterval: Duration = .seconds(5)
  /// The window's real occlusion, read on the main thread. The host sets it; nil without a window.
  var readWindowVisible: (() -> Bool)?
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
    startLoop()
  }
  /// The one place a loop starts, and it ends the one before. Only `close` leaves no loop.
  private func startLoop() {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let pause = await self?.tick() else { return }
        do { try await Task.sleep(for: pause) } catch { return }
      }
    }
  }
  private func tick() async -> Duration {
    // A notification may have been missed. This tick reads anyway, so the loop needs no restart.
    if !windowVisible, readWindowVisible?() == true { windowVisible = true }
    await refresh()
    return windowVisible ? refreshInterval : hiddenRefreshInterval
  }
  /// Showing ends the slow sleep and reads at once. Hiding touches nothing but the pace of the next sleep.
  public func setWindowVisible(_ visible: Bool) {
    guard !closed else { return }
    let showing = visible && !windowVisible
    windowVisible = visible
    if showing || refreshTask == nil { startLoop() }
  }
  func windowOcclusionChanged() {
    if let readWindowVisible { setWindowVisible(readWindowVisible()) }
  }
  public func refresh() async {
    guard !closed else { return }
    // A caller that finds a read running may have a reason the running read predates or will discard.
    guard !reading else { refreshAgain = true; return }
    reading = true
    defer {
      reading = false
      if refreshAgain { refreshAgain = false; Task { await refresh() } }
    }
    do {
      // A selection made during a slow read wins; never publish a stale day over it.
      var revision: Int
      var value: AppWindowSnapshot
      repeat {
        revision = selectionRevision
        value = try await read(selectedDate)
        guard !closed, !Task.isCancelled else { return }
      } while revision != selectionRevision
      // Publishing redraws the whole window, so a second in which nothing changed publishes nothing.
      if snapshot?.looksTheSame(as: value) != true { snapshot = value }
      if settings.health != value.health { settings.health = value.health }
      settings.refresh()
      if readFailed { readFailed = false }
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
    let days = AppWindowDayReader(open: { try composition.queryStorage() }, edits: edits, health: health, chatGPT: chatGPT)
    let model = AppWindowModel(settings: settings, makeConversation: {
      try ConversationController(store: edits) { selection, skip in
        let configuration = composition.conversation(command: selection.provider == .codex ? codex : claude, skipApprovals: skip)
        return composition.factories.conversationAgent(selection.provider, configuration, conversationTokens)
      }
    }, readDay: { selectedDate in
      try await Task.detached { try days.read(selectedDate: selectedDate) }.value
    }, readMonth: { month in
      try await Task.detached {
        let store = try composition.queryStorage()
        return try store.withQuerySnapshot {
          try TimelineDay.recordedDays(inMonth: month, dayStartHour: store.settings().dayStartHour,
            calendar: .current, storage: store)
        }
      }.value
    })
    days.healthChanged = { [weak model] in Task { @MainActor in await model?.refresh() } }
    return (model, edits)
  }
}

/// The window's background read, once a second on screen and every five seconds hidden.
///
/// Settings and notices are read every time. The grid is the one costly part, and it is kept while
/// its `Key` stays equal: same day, same minute, same revision of everything it is computed from.
/// Only one grid is kept, and only the read that computed it can be reused, so nothing removed comes back.
///
/// Health is checked beside the read, never inside it. It can stall (fdesetup for up to 10 s, the Keychain
/// for a time nobody has measured), and removed data must not stay on screen behind it. Each read asks for
/// a check unless one is running and uses the last answer; an answer that differs asks for another read.
/// The Keychain answers apart from the rest, so a stalled one holds up nothing but its own ChatGPT value.
final class AppWindowDayReader {
  /// How long a window says nothing about health that has not answered. A little over fdesetup's own 10 s.
  static let healthAnswerLimit = 15
  private struct Key: Equatable {
    /// A time zone change moves this too, as the day's boundary is a local hour.
    let range: TimeRange
    /// Moves the visible end and the now column, and also bounds the life of a kept grid to a minute on
    /// every day shown, whatever a future write path might do that the revision does not see.
    let minute: Int
    let revision: TimelineDayRevision
  }
  private let open: () throws -> ActivityStorage
  private let edits: ActivityStorage
  private let health: () -> TimelineHealth
  private let chatGPT: ChatGPTStatusReader
  private let clock: () -> Int
  private let calendar: () -> Calendar
  private let lock = NSLock()
  private var store: ActivityStorage?
  private var kept: (key: Key, day: TimelineDay, failures: [TimeRange])?
  private let healthLock = NSLock()
  private var lastHealth: TimelineHealth?
  private var lastChatGPT: ChatGPTConnectionStatus?
  private var firstAsked: Int?
  private var healthRunning = false
  private let runHealth: (@escaping () -> Void) -> Void
  /// Runs off the main thread when a finished check differs from the last one. Set before the first read.
  var healthChanged: (() -> Void)?
  /// How many reads computed the grid, for tests.
  private(set) var gridReads = 0
  init(open: @escaping () throws -> ActivityStorage, edits: ActivityStorage, health: @escaping () -> TimelineHealth, chatGPT: ChatGPTStatusReader,
    clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }, calendar: @escaping () -> Calendar = { .current },
    runHealth: ((@escaping () -> Void) -> Void)? = nil) {
    self.open = open; self.edits = edits; self.health = health; self.chatGPT = chatGPT; self.clock = clock; self.calendar = calendar
    // Its own thread: this blocks, and must not take one from the pool that reads the grid.
    let queue = DispatchQueue(label: "ActivityProbe.window-health", qos: .utility)
    self.runHealth = runHealth ?? { queue.async(execute: $0) }
  }
  private func checkHealth(now: Int) {
    healthLock.lock()
    let idle = !healthRunning
    healthRunning = true
    if firstAsked == nil { firstAsked = now }
    healthLock.unlock()
    guard idle else { return }
    let health = health, chatGPT = chatGPT
    runHealth { [weak self] in
      let value = health()
      guard let self else { return }
      self.healthReturned(value)
      chatGPT.check { [weak self] in self?.chatGPTReturned($0) }
    }
  }
  private func healthReturned(_ answer: TimelineHealth) {
    healthLock.lock()
    var value = answer
    value.chatGPT = lastChatGPT
    let changed = lastHealth != value
    lastHealth = value; healthRunning = false
    healthLock.unlock()
    if changed { healthChanged?() }
  }
  private func chatGPTReturned(_ status: ChatGPTConnectionStatus) {
    healthLock.lock()
    lastChatGPT = status
    let changed = lastHealth != nil && lastHealth?.chatGPT != status
    lastHealth?.chatGPT = status
    healthLock.unlock()
    if changed { healthChanged?() }
  }
  /// Either way round: a clock set back must not extend the silence.
  private func healthOverdue(now: Int) -> Bool {
    healthLock.lock(); defer { healthLock.unlock() }
    return firstAsked.map { abs(now - $0) >= Self.healthAnswerLimit } ?? false
  }
  private func latestHealth() -> TimelineHealth? {
    healthLock.lock(); defer { healthLock.unlock() }
    return lastHealth
  }
  func read(selectedDate: Date?) throws -> AppWindowSnapshot {
    lock.lock(); defer { lock.unlock() }
    do { return try readCurrent(selectedDate: selectedDate) }
    catch { store = nil; kept = nil; throw error }
  }
  private func currentStore() throws -> ActivityStorage {
    if let store, store.openedFileIsCurrent { return store }
    kept = nil; store = nil
    let opened = try open()
    store = opened
    return opened
  }
  private func readCurrent(selectedDate: Date?) throws -> AppWindowSnapshot {
    let store = try currentStore()
    let now = clock(), calendar = calendar()
    checkHealth(now: now)
    let known = latestHealth()
    var current = known ?? .unread
    var displayed = current
    var dayStartHour = TimelineDay.defaultDayStartHour
    var day = try store.withQuerySnapshot {
      let saved = try store.settings()
      dayStartHour = saved.dayStartHour
      let shown = try selectedDate.map { try TimelineDay.range(on: $0, dayStartHour: saved.dayStartHour, calendar: calendar).start } ?? now
      if current.summary != nil { current.summary?.subscriptionConnected = saved.claudeConnected }
      if let until = try store.summaryUnavailableUntil(), until > Double(now) {
        if current.summary == nil { current.summary = SummaryHealth() }
        current.summary?.subscriptionConnected = saved.claudeConnected
        current.summary?.serviceUnavailableUntil = until
        current.summary?.planUsePaused = true
      }
      displayed = current
      let range = try TimelineDay.range(containing: shown, dayStartHour: saved.dayStartHour, calendar: calendar)
      let key = Key(range: range, minute: TimelineDay.floorMinute(now),
        revision: try store.timelineDayRevision(day: range, visible: TimelineDay.visibleRange(of: range, now: now)))
      let reused = kept?.key == key ? kept : nil
      let failures = try reused?.failures ?? SummaryHealth.unresolvedFailedRanges(in: store.modelCalls(overlapping: range))
      var summary = displayed.summary ?? SummaryHealth(); summary.subscriptionConnected = saved.claudeConnected
      summary.failedRanges = failures; displayed.summary = summary
      if var day = reused?.day {
        day.notices = TimelineNotices.make(settings: saved, health: displayed)
        return day
      }
      kept = nil
      let day = try TimelineDay.read(containing: shown, now: now, calendar: calendar, storage: store, health: displayed)
      kept = (key, day, failures); gridReads += 1
      return day
    }
    // No check has answered yet, so nothing is known about FileVault and no problem is known to have gone.
    // Past the limit, that is what the window says: a check that never answers must not look like no problem.
    if known == nil, !healthOverdue(now: now) { day.notices.removeAll { $0.kind == .fileVaultUnknown } }
    // Resolve against the latest settings inside the patch transaction, preserving concurrent edits.
    if known != nil, try TimelineNotices.resolved(settings: store.settings(), health: current) != nil {
      _ = try edits.patchSettings(.resolveTimelineNotices(current))
    }
    return AppWindowSnapshot(day: day, health: displayed, dayStartHour: dayStartHour, now: now)
  }
}

/// The ChatGPT status for the timeline's notice. It reads the Keychain, at most once per `interval`, and never
/// on the main thread or the recorder's sampling. The Keychain has no time limit, so nobody waits for it here:
/// one read at a time runs on this reader's own thread, and the process has one reader. However many windows
/// open and close during a stall, that stall holds one thread.
public final class ChatGPTStatusReader {
  static let interval: TimeInterval = 30
  private let account: ChatGPTAccount
  private let clock: () -> TimeInterval
  private let run: (@escaping () -> Void) -> Void
  private let lock = NSLock()
  private var last: (at: TimeInterval, status: ChatGPTConnectionStatus)?
  private var reading = false
  /// One, the latest to ask. Only one window exists at a time, and a closed one has nothing left to tell.
  private var waiter: ((ChatGPTConnectionStatus) -> Void)?
  init(account: ChatGPTAccount, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    run: ((@escaping () -> Void) -> Void)? = nil) {
    self.account = account; self.clock = clock
    let queue = DispatchQueue(label: "ActivityProbe.window-keychain", qos: .utility)
    self.run = run ?? { queue.async(execute: $0) }
  }
  /// Returns at once. `answered` gets a recent status now, or the next one when the read that is due has ended.
  func check(answered: @escaping (ChatGPTConnectionStatus) -> Void) {
    lock.lock()
    if let last, clock() - last.at < Self.interval {
      lock.unlock()
      answered(last.status)
      return
    }
    waiter = answered
    let idle = !reading
    reading = true
    lock.unlock()
    guard idle else { return }
    run { [self] in
      let status = account.status()
      lock.lock()
      // From the end of the read, so a long stall is not followed by another read at once.
      last = (clock(), status); reading = false
      let waiter = waiter
      self.waiter = nil
      lock.unlock()
      waiter?(status)
    }
  }
}
