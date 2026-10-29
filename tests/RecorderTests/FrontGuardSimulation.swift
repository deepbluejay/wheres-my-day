import Core
import Foundation
@testable import Inbound

/// Hours of invented switching against the real MacFrontWindowSource, with fake boundary and
/// time. NSWorkspace follows the true front `lag` seconds after each switch (or a lag drawn
/// from `lags`), in order; the gate asks every second; the call answers by `Call`. A share
/// `handOffs` of the switches is followed 20 ms later by another, as when an app hands focus
/// on. After a disable the recorder is taken as restarted, so `disables` counts them all.
extension FrontProcessTests {
  enum Usage {
    /// Switches `range` seconds apart throughout.
    case every(ClosedRange<Double>)
    /// Bursts of 10-60 s switching every 0.3-1.0 s, with a dwell of 5-120 s between them.
    case mixed
  }
  enum Call {
    case honest
    /// Always pid 10, an application among the ones the person switches to.
    case stuck
    /// Always a process without an application identity.
    case stuckWithoutIdentity
    /// The front of `seconds` ago.
    case late(Double)
    /// The front before the current one.
    case oneSwitchBehind
    /// Pid 10 and pid 11 on alternate reads.
    case alternating
    /// The front sampled every `seconds`, held in between.
    case held(Double)
    /// Pid 10 on `share` of the reads, the true front otherwise.
    case stale(Double)
  }
  struct Run: CustomStringConvertible {
    var compares = 0, disagreements = 0, activationDisagreements = 0, disables = 0, firstDisable: Double?
    var asks = 0, wrong = 0, mainHops = 0, mainReadsPerCompare = 0
    var shortestCheckGap = Double.infinity
    var wrongShare: Double { Double(wrong) / Double(max(asks, 1)) }
    var description: String {
      let first = firstDisable.map { "\(Int($0)) s" } ?? "never"
      return "compares \(compares), disagreements \(disagreements) (on activation \(activationDisagreements)), disables \(disables), first disable \(first), "
        + String(format: "wrong %.2f%%", wrongShare * 100)
        + ", main hops \(mainHops), main reads per compare \(mainReadsPerCompare), shortest check gap \(shortestCheckGap)"
    }
  }
  static func simulate(_ usage: Usage, _ call: Call, lag: Double = 0, lags: ClosedRange<Double>? = nil,
    handOffs: Double = 0, applications: Int = 4, hours: Double = 8, seed: UInt64 = 7) -> Run
  {
    var random = Seeded(state: seed), callRandom = Seeded(state: seed &+ 1), switchRandom = Seeded(state: seed &+ 2)
    let pids = (0..<applications).map { Int32(10 + $0) }
    var now = 100.0
    let begin = now, end = now + hours * 3600
    var history: [(time: Double, pid: Int32)] = [(begin, 10)]
    var workspace: Int32 = 10
    var deliveries: [(time: Double, pid: Int32)] = []
    var lastDelivery = -Double.infinity, handingOff = false
    // Mixed use opens with a burst: no check can tell a stuck call before the first switch.
    var burstEnd = -Double.infinity
    if case .mixed = usage { burstEnd = now + Double.random(in: 10...60, using: &random) }
    func gap() -> Double {
      switch usage {
      case .every(let range): return Double.random(in: range, using: &random)
      case .mixed:
        let quick = Double.random(in: 0.3...1.0, using: &random)
        if now + quick <= burstEnd { return quick }
        let dwell = Double.random(in: 5...120, using: &random)
        burstEnd = now + dwell + Double.random(in: 10...60, using: &random)
        return dwell
      }
    }
    func front(at time: Double) -> Int32 { history.last { $0.time <= time }?.pid ?? history[0].pid }
    var reads = 0
    func answer() -> FrontProcess {
      let pid: Int32
      switch call {
      case .honest: pid = history[history.count - 1].pid
      case .stuck: pid = 10
      case .stuckWithoutIdentity: pid = 9
      case .late(let seconds): pid = front(at: now - seconds)
      case .oneSwitchBehind: pid = history[max(history.count - 2, 0)].pid
      case .alternating: reads += 1; pid = reads % 2 == 0 ? 10 : 11
      case .held(let seconds): pid = front(at: begin + ((now - begin) / seconds).rounded(.down) * seconds)
      case .stale(let share): pid = Double.random(in: 0..<1, using: &callRandom) < share ? 10 : history[history.count - 1].pid
      }
      return FrontProcess(pid: pid, serial: UInt64(pid))
    }
    var run = Run(), runs: [Fakes] = []
    func start() -> Fakes {
      let fakes = Fakes()
      for pid in pids { fakes.applications[pid] = "invented.app\(pid)" }
      fakes.now = now; fakes.workspace = workspace
      fakes.call = { answer() }
      fakes.mainProcess = { [unowned fakes] in fakes.workspace ?? 99 }
      _ = fakes.source  // registers for activations
      return fakes
    }
    var fakes = start()
    var nextSwitch = now + gap(), nextAsk = now + 1, lastCompare = -Double.infinity
    while now < end {
      now = min(nextSwitch, nextAsk, deliveries.first?.time ?? .infinity)
      fakes.now = now
      let compares = fakes.comparisons
      if let delivery = deliveries.first, delivery.time == now {
        deliveries.removeFirst(); workspace = delivery.pid; fakes.activate(delivery.pid)
      } else if nextSwitch == now {
        let next = pids.filter { $0 != history[history.count - 1].pid }.randomElement(using: &random)!
        let delay = lags.map { Double.random(in: $0, using: &switchRandom) } ?? lag
        lastDelivery = max(now + delay, lastDelivery)
        history.append((now, next)); deliveries.append((lastDelivery, next))
        handingOff = !handingOff && handOffs > 0 && Double.random(in: 0..<1, using: &switchRandom) < handOffs
        nextSwitch = handingOff ? now + 0.02 : now + gap()
      } else {
        run.asks += 1
        if fakes.source.frontApplication().processID != history[history.count - 1].pid { run.wrong += 1 }
        nextAsk = now + 1
      }
      if fakes.comparisons > compares { run.shortestCheckGap = min(run.shortestCheckGap, now - lastCompare); lastCompare = now }
      if fakes.counted[.disabled] != nil {
        run.firstDisable = run.firstDisable ?? now - begin
        runs.append(fakes); fakes = start(); lastCompare = -Double.infinity
      }
    }
    runs.append(fakes)
    for fakes in runs {
      run.compares += fakes.counted[.comparisons] ?? 0
      run.disagreements += fakes.counted[.disagreements] ?? 0
      run.activationDisagreements += fakes.activationDisagreements
      run.disables += fakes.counted[.disabled] ?? 0
      run.mainHops += fakes.mainHops
      run.mainReadsPerCompare = max(run.mainReadsPerCompare, fakes.mainReadsPerCompare)
    }
    return run
  }
}
