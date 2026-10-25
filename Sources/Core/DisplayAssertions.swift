import Foundation

public struct DisplayApp {
  public var pid: Int32
  public var path: String
  public init(pid: Int32, path: String) {
    self.pid = pid
    self.path = path
  }
}
public struct DisplayProcess {
  public var parent: Int32
  public var path: String
  public init(parent: Int32, path: String) {
    self.parent = parent
    self.path = path
  }
}
public struct DisplayAssertion {
  public var pid: Int32
  public var type: String
  public var enabled: Bool
  public var onBehalfOf: Int32?
  public init(pid: Int32, type: String, enabled: Bool, onBehalfOf: Int32? = nil) {
    self.pid = pid
    self.type = type
    self.enabled = enabled
    self.onBehalfOf = onBehalfOf
  }
}
public enum DisplayAssertionPolicy {
  public static func owner(
    of pid: Int32, apps: [DisplayApp],
    process: (Int32) -> DisplayProcess?
  ) -> Int32? {
    let apps = apps.filter { $0.path.hasSuffix(".app") }
    func outer(_ app: DisplayApp) -> Int32? {
      let roots = apps.filter { app.path == $0.path || app.path.hasPrefix($0.path + "/") }
      let shortest = roots.map { $0.path.count }.min()
      let candidates = roots.filter { $0.path.count == shortest }
      if candidates.count == 1 { return candidates.first?.pid }
      return candidates.contains { $0.pid == app.pid } ? app.pid : nil
    }
    if let direct = apps.first(where: { $0.pid == pid }),
      !apps.contains(where: { direct.path.hasPrefix($0.path + "/") })
    {
      return direct.pid
    }
    guard let owner = process(pid) else { return nil }
    let containing = apps.filter { owner.path.hasPrefix($0.path + "/") }
    let shortest = containing.map { $0.path.count }.min()
    let candidates = containing.filter { $0.path.count == shortest }
    if candidates.count == 1 { return candidates.first?.pid }
    guard !candidates.isEmpty || owner.path.contains(".xpc/") else { return nil }
    var parent = owner.parent
    var visited: Set<Int32> = [pid]
    for _ in 0..<32 {
      guard parent > 1, visited.insert(parent).inserted else { break }
      if let app = apps.first(where: { $0.pid == parent }), let owner = outer(app) { return owner }
      guard let ancestor = process(parent) else { break }
      parent = ancestor.parent
    }
    return nil
  }
  public static func keepingAwake(
    _ pid: Int32, assertions: [DisplayAssertion], apps: [DisplayApp],
    process: (Int32) -> DisplayProcess?
  ) -> Bool {
    assertions.contains {
      $0.enabled && ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"].contains($0.type)
        && owner(of: $0.onBehalfOf ?? $0.pid, apps: apps, process: process) == pid
    }
  }
}
