import Core
import Foundation

/// Claude has no documented noninteractive model catalog. Offer stable aliases with
/// the common effort levels documented at code.claude.com/docs/en/model-config.
public final class ClaudeConversationAgent: ConversationAgent {
  public let provider = ChatProvider.claude
  private let configuration: ConversationConfiguration
  public init(configuration: ConversationConfiguration) { self.configuration = configuration }
  public func models() throws -> [ChatModel] {
    ["sonnet", "opus"].map { ChatModel(id: $0, reasoningLevels: ["low", "medium", "high", "max"]) }
  }
  public func converse(messages: [ConversationMessage], selection: ChatSelection) -> AsyncThrowingStream<ConversationEvent, Error> {
    ConversationEncoding.stream { [configuration] cancellation, continuation in
      guard selection.provider == .claude, try self.models().contains(where: { $0.accepts(selection) }) else {
        throw ConversationError.invalidSelection
      }
      let text = try ConversationEncoding.transcript(messages, guidance: configuration.guidance)
      try configuration.prepare()
      let launch = try configuration.claudeLaunch()
      // The person's own login, as their terminal has it. Only the login method is read, for billing.
      let auth = try ConversationProcess.metadata(executable: launch.executable, arguments: ["--settings", String(decoding: try ConversationEncoding.json(ConversationDiagnostics.claudeSettings), as: UTF8.self), "auth", "status", "--json"],
        environment: launch.environment, cwd: configuration.userHome, cancellation: cancellation, exitErrors: [1: .notLoggedIn])
      let account = try ConversationEncoding.object(Data(auth.utf8))
      guard account["loggedIn"] as? Bool == true else { throw ConversationError.notLoggedIn }
      let method = account["authMethod"] as? String ?? ""
      continuation.yield(.billing(["claude.ai", "oauth_token"].contains(method) ? .subscription : .external))
      let runtime = try ConversationRuntime(configuration)
      let server: [String: Any] = ["command": configuration.toolServer.path, "args": [String](), "env": runtime.toolEnvironment]
      let config = try ConversationEncoding.json(["mcpServers": [QueryToolContract.serverName: server]])
      let settings = try ConversationEncoding.json(configuration.claudeConversationSettings(work: runtime.folder, personal: launch.personal))
      // No setting source, no slash commands, only our MCP server and no saved session: the person's own
      // settings, hooks, plugins, skills, agents, output style, MCP servers and history stay out of it.
      var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages", "--no-session-persistence", "--setting-sources", "", "--disable-slash-commands",
        "--strict-mcp-config", "--mcp-config",
        String(decoding: config, as: UTF8.self), "--permission-mode", "manual", "--permission-prompts", "host",
        "--settings", String(decoding: settings, as: UTF8.self), "--model", selection.model, "--effort", selection.reasoning]
      arguments += ["--allowedTools", QueryToolContract.qualifiedNames.sorted().joined(separator: ",")]
      if configuration.skipApprovals { arguments += ["--dangerously-skip-permissions"] }
      let approvals = ConversationApprovals(timeout: configuration.approvalTimeout) { continuation.yield($0) }
      var parser = ClaudeConversationWire()
      let input = try ConversationEncoding.json(["type": "user", "message": ["role": "user", "content": text]])
      var answerBytes = 0
      try ConversationProcess.exchange(executable: launch.executable, arguments: arguments,
        environment: launch.environment, cwd: runtime.folder, timeout: configuration.timeout,
        cancellation: cancellation, cleanupLease: runtime.lease, service: { send in
          try parser.expireProvisional(send: { try send(ConversationEncoding.json($0)) })
          try approvals.flush(send: send)
        }, isReady: { parser.ready }, initial: [input]) { line, send in
        guard !line.isEmpty else { throw ConversationError.unavailable }
        let value = try ConversationEncoding.object(line)
        let events = try parser.receive(value, approvals: approvals, send: { try send(ConversationEncoding.json($0)) }, emit: { events in
          for event in events {
            if case .text(let text) = event {
              answerBytes += text.utf8.count
              guard answerBytes <= 4 * 1024 * 1024 else { throw ConversationError.outputLimit }
            }
            continuation.yield(event)
          }
        })
        return events.contains(.completed)
      }
      withExtendedLifetime(runtime) {}
    }
  }
}

struct ClaudeConversationWire {
  var ready = false
  struct RunState {
    var id: String?
    var generation = 0
    var streamedMessage: String?
    var streamed = false
    var tools = Set<String>()
    var finished = false
  }
  struct TaskState {
    let parent: String?
    var agent: String?
    var activeSpawn: String
    var run = RunState()
  }
  // A spawn proves ancestry once. A native task keeps that proof across runs.
  // Only run state (including approval scope) changes on task_started.
  var tasks: [String: TaskState] = ["": TaskState(parent: nil, activeSpawn: "")]
  var spawns: [String: String] = [:]
  var spawnGenerations: [String: Int] = [:]
  var agents: [String: String] = [:]
  var provisional = ConversationProvisionalThreads()

  private var aliases: [String: String] {
    var result = Dictionary(uniqueKeysWithValues: spawns.map { ("parent:" + $0.key, $0.value) })
    for (agent, scope) in agents {
      result["agent:" + agent] = scope
      if tasks[scope]?.run.finished == false { result["next:" + agent] = scope }
    }
    for (scope, task) in tasks {
      if let id = task.run.id { result[runKey(scope, id)] = scope }
    }
    return result
  }
  private func runKey(_ scope: String, _ id: String) -> String { "run:\(scope.utf8.count):\(scope)\(id)" }
  private func approvalScope(_ scope: String) -> String {
    "\(scope.utf8.count):\(scope):\(tasks[scope]!.run.generation)"
  }
  private func isTaskFrame(_ line: [String: Any]) -> Bool {
    line["type"] as? String == "system" &&
      ["task_started", "task_notification", "task_updated", "task_progress"].contains(line["subtype"] as? String ?? "")
  }
  private func refuse(_ value: [String: Any], send: ([String: Any]) throws -> Void) throws {
    if value["type"] as? String == "control_request", let id = value["request_id"] {
      try send(["type": "control_response", "response": ["subtype": "success", "request_id": id,
        "response": ["behavior": "deny", "message": "Unverified or completed agent."]]])
    }
  }
  mutating func expireProvisional(now: TimeInterval = ProcessInfo.processInfo.systemUptime,
    send: ([String: Any]) throws -> Void) throws {
    for value in try provisional.expire(now: now) { try refuse(value, send: send) }
  }
  mutating func receive(_ line: [String: Any], approvals: ConversationApprovals? = nil,
    send: ([String: Any]) throws -> Void = { _ in }, emit: (([ConversationEvent]) throws -> Void)? = nil) throws -> [ConversationEvent] {
    try receiveFrame(line, approvals: approvals, send: send, emit: emit, replaying: false)
  }
  private mutating func receiveFrame(_ line: [String: Any], approvals: ConversationApprovals?,
    send: ([String: Any]) throws -> Void, emit: (([ConversationEvent]) throws -> Void)?, replaying: Bool) throws -> [ConversationEvent] {
    try expireProvisional(send: send)
    let type = line["type"] as? String ?? ""
    var key: String?
    if let parent = line["parent_tool_use_id"] as? String { key = "parent:" + parent }
    else if ["assistant", "user"].contains(type), let agent = line["agent_id"] as? String { key = "agent:" + agent }
    if type == "control_cancel_request", let id = line["request_id"] as? String {
      key = provisional.thread { $0["type"] as? String == "control_request" && $0["request_id"] as? String == id }
    }
    if type == "control_request", let request = line["request"] as? [String: Any], let agent = request["agent_id"] as? String {
      key = "agent:" + agent
    }
    if isTaskFrame(line) {
      // Stable task identity wins over the optional tool ID, which on resume
      // may identify SendMessage, the original spawn, or nothing at all.
      if let agent = line["task_id"] as? String, let scope = agents[agent] {
        if let current = tasks[scope]?.run.id {
          guard let id = line["run_id"] as? String, id >= current else { return [] }
        }
        if line["subtype"] as? String == "task_started", let tool = line["tool_use_id"] as? String,
          let spawned = spawns[tool], spawned != scope { try bind(agent, scope: spawned) }
        key = "agent:" + agent
      }
      else if let tool = line["tool_use_id"] as? String {
        if spawns[tool] != nil { key = "parent:" + tool }
        else if !tasks.values.contains(where: { $0.run.tools.contains(tool) }) { key = "parent:" + tool }
      } else if let agent = line["task_id"] as? String { key = "agent:" + agent }
    }
    if let scope = key.flatMap({ aliases[$0] }), !scope.isEmpty {
      if let parent = line["parent_tool_use_id"] as? String, parent != tasks[scope]?.activeSpawn {
        try refuse(line, send: send); return []
      }
      if let id = line["run_id"] as? String, let current = tasks[scope]?.run.id,
        id < current { return [] }
      // Requests and complete child messages have no native run ID. Between
      // runs, hold them until an explicit start admits the next generation.
      if !isTaskFrame(line), tasks[scope]?.run.finished == true,
        let agent = tasks[scope]?.agent { key = "next:" + agent }
      if line["subtype"] as? String != "task_started",
        let id = line["run_id"] as? String, id != tasks[scope]?.run.id {
        key = runKey(scope, id)
      }
    }
    if let key, aliases[key] == nil {
      do {
        if try provisional.hold(line, thread: key) { return [] }
      } catch {
        for value in try provisional.discardAll() { try refuse(value, send: send) }
        try refuse(line, send: send); throw error
      }
      try refuse(line, send: send); return []
    }
    var scope = key.flatMap { aliases[$0] } ?? ""
    try verifyAlias(line, scope: scope)
    scope = key.flatMap { aliases[$0] } ?? scope
    var events = try admitStart(line, scope: scope, approvals: approvals)
    try emit?(events)
    if !replaying { events += try replay(approvals: approvals, send: send, emit: emit) }
    let current = try receiveVerified(line, scope: scope, approvals: approvals, send: send)
    events += current; try emit?(current.filter { $0 != .completed })
    if !replaying { events += try replay(approvals: approvals, send: send, emit: emit) }
    if events.contains(.completed) {
      for scope in tasks.keys { approvals?.resolve(thread: approvalScope(scope), turn: "") }
      for value in try provisional.discardAll() { try refuse(value, send: send) }
      try emit?([.completed])
    }
    return events
  }
  private mutating func bind(_ agent: String, scope: String) throws {
    guard !agent.isEmpty, !scope.isEmpty, tasks[scope] != nil,
      !provisional.isRejected("agent:" + agent),
      tasks[scope]?.agent == nil || tasks[scope]?.agent == agent else { throw ConversationError.incompatible }
    if let previous = agents[agent], previous != scope {
      // Older producers may announce another verified spawn for the same task.
      // Keep the original ancestry and retire the old spawn's message channel.
      guard tasks[previous]?.run.finished == true, tasks[previous]?.parent == tasks[scope]?.parent,
        tasks[scope]!.run.tools.isEmpty else { throw ConversationError.incompatible }
      tasks[previous]?.activeSpawn = scope
      tasks.removeValue(forKey: scope)
      spawns[scope] = previous
      spawnGenerations[scope] = tasks[previous]!.run.generation + 1
    } else {
      agents[agent] = scope
      tasks[scope]?.agent = agent
    }
  }
  private mutating func verifyAlias(_ line: [String: Any], scope: String) throws {
    guard !scope.isEmpty else { return }
    if let agent = line["task_id"] as? String, let known = agents[agent],
      let id = line["run_id"] as? String, let current = tasks[known]?.run.id, id < current { return }
    if ["assistant", "user"].contains(line["type"] as? String ?? ""),
      tasks[scope]?.run.finished == false, let agent = line["agent_id"] as? String { try bind(agent, scope: scope) }
    if isTaskFrame(line), let agent = line["task_id"] as? String { try bind(agent, scope: scope) }
  }
  private mutating func admitStart(_ line: [String: Any], scope: String,
    approvals: ConversationApprovals?) throws -> [ConversationEvent] {
    guard !scope.isEmpty, isTaskFrame(line), line["subtype"] as? String == "task_started" else { return [] }
    let id = line["run_id"] as? String
    let run = tasks[scope]!.run
    // Once numbered runs are available, unnumbered task frames cannot reset
    // or end them. Legacy producers use explicit starts in arrival order.
    if let current = run.id {
      guard let id, id > current else { return [] }
    } else if !run.finished {
      tasks[scope]?.run.id = id
      return []
    }
    if let agent = tasks[scope]?.agent, provisional.isRejected("next:" + agent) {
      throw ConversationError.incompatible
    }
    if let id, provisional.isRejected(runKey(scope, id)) { throw ConversationError.incompatible }
    let events = finish(scope, approvals: approvals)
    tasks[scope]?.run = RunState(id: id, generation: run.generation + 1)
    return events
  }
  private mutating func replay(approvals: ConversationApprovals?, send: ([String: Any]) throws -> Void,
    emit: (([ConversationEvent]) throws -> Void)?) throws -> [ConversationEvent] {
    var events: [ConversationEvent] = []
    while true {
      // Join identities before replay, preserving the original combined order.
      for key in provisional.identities {
        if aliases[key] != nil {
          for value in provisional.events(for: key) {
            if let scope = aliases[key] { try verifyAlias(value, scope: scope) }
          }
        }
      }
      guard let (_, value) = provisional.takeFirst(verified: Set(aliases.keys)) else { break }
      // Use the same admission and run guards for replayed and live frames.
      let next = try receiveFrame(value, approvals: approvals, send: send, emit: emit, replaying: true)
      events += next
    }
    return events
  }
  private mutating func finish(_ scope: String, approvals: ConversationApprovals?) -> [ConversationEvent] {
    guard tasks[scope]?.run.finished == false else { return [] }
    approvals?.resolve(thread: approvalScope(scope), turn: "")
    tasks[scope]?.run.finished = true
    let events = tasks[scope]!.run.tools.sorted().map { ConversationEvent.toolFinished(id: toolID(scope: scope, item: $0), failed: true) }
    tasks[scope]?.run.tools.removeAll()
    return events
  }
  private mutating func receiveVerified(_ line: [String: Any], scope: String,
    approvals: ConversationApprovals?, send: ([String: Any]) throws -> Void) throws -> [ConversationEvent] {
    let type = line["type"] as? String ?? ""
    if type == "system", line["subtype"] as? String == "init" {
      guard !ready, scope.isEmpty, let names = line["tools"] as? [String], QueryToolContract.qualifiedNames.isSubset(of: Set(names)),
        let servers = line["mcp_servers"] as? [[String: Any]], servers.count == 1,
        servers[0]["name"] as? String == QueryToolContract.serverName, servers[0]["status"] as? String == "connected" else {
        throw ConversationError.incompatible
      }
      ready = true; return [.started]
    }
    guard ready else {
      if type == "system" { return [] }
      throw ConversationError.incompatible
    }
    if tasks[scope]?.run.finished == true {
      try refuse(line, send: send); return []
    }
    switch type {
    case "control_request":
      guard let approvals else { throw ConversationError.incompatible }
      try approvals.claude(line, thread: approvalScope(scope)); return []
    case "control_cancel_request":
      if let id = line["request_id"] { try approvals?.resolve(wireID: id) }
    case "stream_event":
      // The documented CLI forwards token deltas for the main session only.
      guard scope.isEmpty, let event = line["event"] as? [String: Any] else { throw ConversationError.incompatible }
      if event["type"] as? String == "message_start" {
        tasks[scope]?.run.streamedMessage = (event["message"] as? [String: Any])?["id"] as? String
        tasks[scope]?.run.streamed = false
      }
      if event["type"] as? String == "content_block_delta", let delta = event["delta"] as? [String: Any],
        delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
        tasks[scope]?.run.streamed = true; return [.text(text)]
      }
    case "assistant":
      guard let message = line["message"] as? [String: Any], message["role"] as? String == "assistant",
        let blocks = message["content"] as? [[String: Any]] else { throw ConversationError.incompatible }
      var result: [ConversationEvent] = []
      for block in blocks {
        if block["type"] as? String == "text", let text = block["text"] as? String,
          !(tasks[scope]!.run.streamed && message["id"] as? String == tasks[scope]!.run.streamedMessage) { result.append(.text(text)) }
        if block["type"] as? String == "tool_use" {
          guard let id = block["id"] as? String, !id.isEmpty,
            let name = block["name"] as? String, !name.isEmpty,
            tasks[scope]!.run.tools.insert(id).inserted else { throw ConversationError.incompatible }
          if ["Agent", "Task"].contains(name) {
            guard spawns[id] == nil, !provisional.isRejected("parent:" + id) else { throw ConversationError.incompatible }
            tasks[id] = TaskState(parent: scope, activeSpawn: id)
            spawns[id] = id
            spawnGenerations[id] = 0
          }
          result.append(.toolStarted(id: toolID(scope: scope, item: id), name: name.hasPrefix("mcp__activityprobe__") ? String(name.dropFirst("mcp__activityprobe__".count)) : name))
        }
      }
      return result
    case "user":
      let blocks = (line["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
      var result: [ConversationEvent] = []
      for block in blocks where block["type"] as? String == "tool_result" {
        guard let id = block["tool_use_id"] as? String, tasks[scope]!.run.tools.remove(id) != nil else {
          throw ConversationError.incompatible
        }
        result.append(.toolFinished(id: toolID(scope: scope, item: id), failed: block["is_error"] as? Bool == true))
        if let child = spawns[id], tasks[child]?.parent == scope, tasks[child]?.activeSpawn == id,
          spawnGenerations[id] == tasks[child]?.run.generation,
          block["is_error"] as? Bool == true || (line["tool_use_result"] as? [String: Any])?["status"] as? String == "completed" {
          result += finish(child, approvals: approvals)
        }
      }
      return result
    case "system":
      let subtype = line["subtype"] as? String
      if isTaskFrame(line), !scope.isEmpty {
        if let current = tasks[scope]?.run.id, line["run_id"] as? String != current { return [] }
        if subtype == "task_notification", let status = line["status"] as? String,
          ["completed", "failed", "stopped"].contains(status) {
          return finish(scope, approvals: approvals)
        }
      }
      // api_retry is advisory; synthetic assistant errors are not terminal either.
    case "result":
      guard scope.isEmpty, line["is_error"] as? Bool == false, tasks.values.allSatisfy({ $0.run.tools.isEmpty }) else {
        throw ConversationError.unavailable
      }
      return [.completed]
    case "error": throw ConversationError.unavailable
    case "tool_progress", "rate_limit_event", "control_response": break
    default: throw ConversationError.incompatible
    }
    return []
  }
  private func toolID(scope: String, item: String) -> String { "\(approvalScope(scope)):\(item)" }
}
