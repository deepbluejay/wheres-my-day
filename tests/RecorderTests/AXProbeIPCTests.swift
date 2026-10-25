import Core
import ApplicationServices
import Foundation
import XCTest
@testable import Inbound

// Only setup/window correspondence is invented; acquisition uses the native provider and extractor.
private final class InventedNativeTree: AXProbeProvider {
  let base: MacAXProbeProvider
  let released: (Int) -> Void
  init(_ base: MacAXProbeProvider, released: @escaping (Int) -> Void) { self.base = base; self.released = released }
  var application: Int { base.application }
  var ipcCount: Int? { base.ipcCount }
  func prepare(_ node: Int, timeout: Double) -> AXProbeValue? { base.prepare(node, timeout: timeout) }
  func releaseObservation(_ node: Int) { base.releaseObservation(node); released(base.retainedChildSlots) }
  func releaseNode(_ node: Int) { base.releaseNode(node) }
  func read(_ node: Int, _ attribute: AXProbeAttribute, timeout: Double) -> AXProbeValue {
    if attribute == .manualAccessibility { return .bool(false) }
    if attribute == .focusedWindow { return .node(0) }
    return base.read(node, attribute, timeout: timeout)
  }
  func matchingWindows(_ request: WindowIdentity, frame: AXProbeFrame) -> Bool { true }
}

final class AXProbeIPCTests: XCTestCase {
  private func provider(_ native: AXProbeNativeCalls, permitted: @escaping () -> Bool = { true },
    now: @escaping () -> Double = { 100 }) -> MacAXProbeProvider {
    MacAXProbeProvider(pid: 200001, deadline: 115, permitted: permitted, progress: AXProbeProgress(), native: native, now: now)
  }
  private func inventedNative(_ values: [String: AnyObject]) -> AXProbeNativeCalls {
    var native = AXProbeNativeCalls()
    native.configure = { _, _ in .success }; native.bundle = { _ in "invented.bundle" }
    native.batch = { _, names in (.success, names.map { values[$0] ?? NSNull() } as CFArray) }
    native.single = { _, _ in XCTFail("unexpected single read"); return (.attributeUnsupported, nil) }
    native.page = { _, _, _, _ in XCTFail("unexpected page"); return (.attributeUnsupported, nil) }
    return native
  }
  func testNativeDecoderNullErrorsTypedFrameAttributedStringURLAndRange() {
    var point = CGPoint(x: -20, y: 30), size = CGSize(width: 80, height: 40)
    var range = CFRange(location: 2, length: 8), unsupported = AXError.attributeUnsupported
    let native = inventedNative([
      "AXRole": "AXTextArea" as NSString, "AXPosition": AXValueCreate(.cgPoint, &point)!,
      "AXSize": AXValueCreate(.cgSize, &size)!, "AXVisibleCharacterRange": AXValueCreate(.cfRange, &range)!,
      "AXValue": NSAttributedString(string: "Invented attributed value"),
      "AXURL": URL(string: "https://invented.invalid/item")! as NSURL,
      "AXHelp": AXValueCreate(.axError, &unsupported)!, "AXHidden": kCFBooleanTrue,
    ])
    let p = provider(native)
    XCTAssertNil(p.prepare(0, timeout: 0.05)); XCTAssertEqual(p.calls, 2)
    XCTAssertEqual(p.read(0, .value, timeout: 0.05), .string("Invented attributed value"))
    XCTAssertEqual(p.read(0, .url, timeout: 0.05), .string("https://invented.invalid/item"))
    XCTAssertEqual(p.read(0, .visibleRange, timeout: 0.05), .range(2, 8))
    XCTAssertEqual(p.read(0, .frame, timeout: 0.05), .frame(AXProbeFrame(x: -20, y: 30, width: 80, height: 40)))
    XCTAssertEqual(p.read(0, .help, timeout: 0.05), .unsupported)
    XCTAssertEqual(p.read(0, .title, timeout: 0.05), .unsupported)
    XCTAssertEqual(p.read(0, .hidden, timeout: 0.05), .bool(true))
    var wrong = inventedNative(["AXPosition": AXValueCreate(.cgSize, &size)!, "AXSize": AXValueCreate(.cgPoint, &point)!])
    wrong.single = native.single
    let invalid = provider(wrong); XCTAssertNil(invalid.prepare(0, timeout: 0.05))
    XCTAssertEqual(invalid.read(0, .frame, timeout: 0.05), .unsupported)
  }
  func testNativeEmbeddedAndWholeBatchFallbackAndCannotComplete() {
    for whole in [false, true] {
      var generic = AXError.failure, unsupported = AXError.attributeUnsupported
      var native = inventedNative([:]), singles: [String] = []
      native.batch = { _, names in
        if whole { return (.notImplemented, nil) }
        return (.success, names.map { name in
          name == "AXTitle" ? AXValueCreate(.axError, &generic)! : AXValueCreate(.axError, &unsupported)!
        } as CFArray)
      }
      native.single = { _, name in singles.append(name); return (.success, "Invented fallback" as CFString) }
      let p = provider(native); XCTAssertNil(p.prepare(0, timeout: 0.05))
      XCTAssertEqual(p.read(0, .title, timeout: 0.05), .string("Invented fallback"))
      if whole { XCTAssertGreaterThan(singles.count, 15) } else { XCTAssertEqual(singles, ["AXTitle"]) }
    }
    for whole in [false, true] {
      var failure = AXError.cannotComplete
      var native = inventedNative([:])
      native.batch = { _, names in
        whole ? (.cannotComplete, nil) : (.success, names.map { _ in AXValueCreate(.axError, &failure)! } as CFArray)
      }
      let p = provider(native)
      XCTAssertEqual(p.prepare(0, timeout: 0.05), .failure(-25204)); XCTAssertEqual(p.calls, 1)
    }
  }
  func testNativeCancellationAndDeadlineBetweenMetadataAndValueBatch() {
    for cancelled in [false, true] {
      var allowed = true, now = 100.0, batches = 0
      var native = inventedNative([:])
      native.batch = { _, names in
        batches += 1
        if cancelled { allowed = false } else { now = 115 }
        return (.success, names.map { _ in NSNull() } as CFArray)
      }
      let p = provider(native, permitted: { allowed }, now: { now })
      XCTAssertEqual(p.prepare(0, timeout: 0.05), .stopped(cancelled ? .cancelled : .deadline))
      XCTAssertEqual(batches, 1); XCTAssertEqual(p.calls, 1)
    }
  }
  func testNativeSecureFieldsNeverRequestOrReturnValueAttributes() {
    for identity in ["AXRole", "AXSubrole", "AXIsSecure"] {
      var values: [String: AnyObject] = ["AXTitle": "Invented secure label" as NSString]
      values[identity] = identity == "AXIsSecure" ? kCFBooleanTrue : "AXSecureTextField" as NSString
      var native = inventedNative(values), requested: [String] = []
      let batch = native.batch
      native.batch = { element, names in requested += names; return batch(element, names) }
      let p = provider(native); XCTAssertNil(p.prepare(0, timeout: 0.05))
      XCTAssertEqual(p.calls, 1)
      XCTAssertFalse(requested.contains("AXValue")); XCTAssertFalse(requested.contains("AXSelectedText"))
      for attribute in [AXProbeAttribute.value, .selectedText, .visibleRange, .substring(0, 4)] {
        XCTAssertEqual(p.read(0, attribute, timeout: 0.05), .unsupported)
      }
      XCTAssertEqual(p.read(0, .title, timeout: 0.05), .string("Invented secure label"))
    }
  }
  func testNativeObservationReleasesOwnedAttributedString() {
    weak var owned: NSAttributedString?
    var native = inventedNative([:])
    native.batch = { _, names in
      (.success, names.map { name -> AnyObject in
        guard name == "AXValue" else { return NSNull() }
        let text = NSAttributedString(string: "Invented owned value"); owned = text; return text
      } as CFArray)
    }
    let p = provider(native)
    autoreleasepool { XCTAssertNil(p.prepare(0, timeout: 0.05)) }
    XCTAssertNotNil(owned)
    autoreleasepool { p.releaseObservation(0) }
    XCTAssertNil(owned)
  }
  func testDeepWideNativeArraysReleaseBeforeDescentAndAllUniqueChildrenArePaged() {
    let elements = (0..<80).map { AXUIElementCreateApplication(Int32(200001 + $0)) }
    func index(_ element: AXUIElement) -> Int { elements.firstIndex { CFEqual($0, element) }! }
    // Five distinct full arrays per ancestor, with 50,000 entries each. Only pages may survive descent.
    func children(_ i: Int) -> [AXUIElement] {
      if i < 8 { return [elements[i + 1]] + Array(repeating: elements[79], count: 49_999) }
      return i == 8 ? Array(elements[9...79]) : []
    }
    var native = inventedNative([:]), paged = 0
    weak var active: MacAXProbeProvider?
    native.batch = { element, names in
      let i = index(element)
      return (.success, names.map { name -> AnyObject in
        if ["AXChildren", "AXContents", "AXRows", "AXColumns", "AXTabs"].contains(name) { return NSArray(array: children(i)) }
        if name == "AXRole" { return "AXStaticText" as NSString }
        if name == "AXValue" { return "Invented node \(i)" as NSString }
        return NSNull()
      } as CFArray)
    }
    native.page = { element, _, start, count in
      paged += 1
      XCTAssertEqual(active?.retainedChildSlots, 0)
      let i = index(element)
      let page: [AXUIElement]
      if i < 8 { page = (start..<min(50_000, start + count)).map { $0 == 0 ? elements[i + 1] : elements[79] } }
      else { page = Array(children(i).dropFirst(start).prefix(count)) }
      return (.success, page as CFArray)
    }
    let base = provider(native); active = base
    var maxRetained = 0
    let tree = InventedNativeTree(base) { maxRetained = max(maxRetained, $0) }
    let result = AXProbeExtractor(provider: tree, permitted: { true }, now: { 100 }).acquire(
      WindowIdentity(processID: 200001, windowID: 20))
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.elements, 80); XCTAssertEqual(result.nodes?.count, 80)
    XCTAssertEqual(Set(result.nodes?.compactMap(\.pid) ?? []), Set(200001...200080))
    XCTAssertEqual(result.nodes?.map(\.depth).max(), 9)
    XCTAssertEqual(result.nodes?.flatMap(\.attributes).filter { $0.attribute == "AXValue" }.count, 80)
    XCTAssertEqual(maxRetained, 0); XCTAssertGreaterThan(paged, 8)
  }
  func testIPCCountNoLongerCutsOffFullTreeAtFourThousand() {
    let budget = AXProbeIPCBudget(deadline: 200, permitted: { true }, now: { 100 })
    for _ in 0..<5000 { XCTAssertNil(budget.perform(timeout: 0.05, configure: { _ in 0 }, body: { 0 })) }
    XCTAssertEqual(budget.calls, 5000)
  }
  func testBatchFallbackRetriesOnlyRecoverableErrorsAndKeepsRealMessagingFailures() {
    var calls = 0
    func resolve(_ value: AXProbeValue, batchError: AXProbeValue? = nil) -> AXProbeValue {
      AXProbeBatchRetry.resolve(value, batchError: batchError) { calls += 1; return .string("Invented fallback") }
    }
    XCTAssertEqual(resolve(.string("Invented batch")), .string("Invented batch"))
    XCTAssertEqual(resolve(.unsupported), .unsupported)
    XCTAssertEqual(resolve(.failure(-25204)), .failure(-25204))
    XCTAssertEqual(resolve(.failure(-25202)), .failure(-25202))
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(resolve(.failure(-25200)), .string("Invented fallback"))
    XCTAssertEqual(resolve(.unsupported, batchError: .unsupported), .string("Invented fallback"))
    XCTAssertEqual(calls, 2)
  }
  func testManualAccessibilitySetsOnlyWhenSettable() {
    for state in [AXProbeValue.bool(true), .bool(false), .unsupported, .failure(-25200)] {
      var writes = 0
      let result = AXProbeManualAccessibility.enable(isSettable: { state }, set: { writes += 1; return .bool(true) })
      XCTAssertEqual(writes, state == .bool(true) ? 1 : 0)
      XCTAssertEqual(result, state)
    }
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try! String(contentsOf: repo.appendingPathComponent("Sources/Inbound/MacAXProbe.swift"))
    XCTAssertFalse(source.contains("AXEnhancedUserInterface"))
    XCTAssertTrue(source.contains("AXManualAccessibility"))
    XCTAssertTrue(source.contains("AXUIElementCopyMultipleAttributeValues"))
  }
  func testWatchdogProgressKeepsManualSetupAndEarlierTruncationWithoutText() {
    let progress = AXProbeProgress()
    progress.readStarted()
    progress.update(3, 100, ["manual_accessibility_set": 1, "truncation_depthLimit": 1])
    var result = AXProbeResult(status: .watchdog); result.truncations = ["watchdog": 1]
    progress.copy(into: &result)
    XCTAssertEqual(result.manualAccessibility, "set")
    XCTAssertEqual(result.truncations, ["watchdog": 1, "depthLimit": 1])
    XCTAssertEqual(result.elements, 3); XCTAssertEqual(result.ipc, 1)
    XCTAssertEqual(result.text, ""); XCTAssertNil(result.nodes)
  }
  func testDeadlineAndCancellationBetweenFramePositionAndSizeHaveNoAXError() {
    for expected in [AXProbeStatus.deadline, .cancelled] {
      var now = 100.0, permitted = true, calls = 0
      let budget = AXProbeIPCBudget(deadline: 100.3, permitted: { permitted }, now: { now })
      let body = { calls += 1; return 0 }
      XCTAssertNil(budget.perform(timeout: 0.05, configure: { _ in 0 }, body: body))
      if expected == .deadline { now = 100.3 } else { permitted = false }
      XCTAssertEqual(budget.perform(timeout: 0.05, configure: { _ in 0 }, body: body), .stopped(expected))
      XCTAssertEqual(calls, 1); XCTAssertEqual(budget.calls, 1)
    }
  }
}
