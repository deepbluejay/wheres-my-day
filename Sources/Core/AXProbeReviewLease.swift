import Foundation

/// A review can pause recording only while a short, same-boot heartbeat lease is live.
/// Continuous time bounds sleep and wall rollback without extending the pause.
public struct AXProbeReviewLease: Codable {
  public var boot: String
  public var sessionStart: Double
  public var issued: Double
  public var deadline: Double
  public var issuedWall: Double
  public var deadlineWall: Double
  public static func continuous() -> Double {
    var base = mach_timebase_info_data_t()
    mach_timebase_info(&base)
    return Double(mach_continuous_time()) * Double(base.numer) / Double(base.denom) / 1e9
  }
  /// The boot session cannot change while this process runs.
  public static func bootID() -> String { boot }
  private static let boot: String = {
    var bytes = [CChar](repeating: 0, count: 128), size = 128
    guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
    return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }()
  public func active(wall: Double, continuous: Double, boot: String) -> Bool {
    let numbers = [sessionStart, issued, deadline, issuedWall, deadlineWall, wall, continuous]
    return numbers.allSatisfy(\.isFinite) && !boot.isEmpty && self.boot == boot
      && sessionStart >= 0 && issued >= sessionStart && deadline > issued && deadline - issued <= 10.001
      && deadline <= sessionStart + 1800 && deadlineWall > issuedWall && deadlineWall - issuedWall <= 10.001
      && continuous >= issued && continuous < deadline
  }
}
public extension StorageSettings {
  func axProbeReviewActive(at time: Int, continuous: Double = AXProbeReviewLease.continuous(),
    boot: String = AXProbeReviewLease.bootID()) -> Bool {
    guard general["axProbe.reviewActive"] == "1", let raw = general["axProbe.reviewLease"],
      let lease = try? JSONDecoder().decode(AXProbeReviewLease.self, from: Data(raw.utf8)) else { return false }
    return lease.active(wall: Double(time), continuous: continuous, boot: boot)
  }
}
