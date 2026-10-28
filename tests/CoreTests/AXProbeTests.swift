@testable import Core
import Foundation
import XCTest

private struct ProbeNode {
  var role = "AXStaticText"
  var subrole: String? = ""
  var frame: AXProbeFrame? = AXProbeFrame(x: -100, y: 30, width: 200, height: 80)
  var value = "Invented visible label"
  var children: [Int] = []
  var visible: [Int]? = nil
  var range: (Int, Int)? = nil
  var hidden = false
  var expanded: Bool? = nil
  var selected: Bool? = nil
}
private final class ProbeProvider: AXProbeProvider {
  var application: Int { 0 }
  var nodes: [Int: ProbeNode] = [1: ProbeNode(role: "AXWindow", children: [2]), 2: ProbeNode()]
  var reads: [(Int, AXProbeAttribute)] = []
  var matches = true
  var focus = 1
  var before: ((Int, AXProbeAttribute) -> AXProbeValue?)?
  var timeouts: [Double] = []
  func onScreen(_ frame: AXProbeFrame) -> Bool? { frame.x < 500 }
  func matchingWindows(_ request: WindowIdentity, frame: AXProbeFrame) -> Bool { matches }
  func read(_ node: Int, _ attr: AXProbeAttribute, timeout: Double) -> AXProbeValue {
    reads.append((node, attr)); timeouts.append(timeout)
    if let override = before?(node, attr) { return override }
    if attr == .pid { return .integer(10) }
    if attr == .bundleID { return .string("invented.bundle") }
    if attr == .focusedWindow || attr == .focusedElement { return .node(focus) }
    guard let value = nodes[node] else { return .unsupported }
    switch attr {
    case .role: return .string(value.role)
    case .subrole: return value.subrole.map(AXProbeValue.string) ?? .unsupported
    case .frame: return value.frame.map(AXProbeValue.frame) ?? .unsupported
    case .hidden: return .bool(value.hidden)
    case .selected: return value.selected.map(AXProbeValue.bool) ?? .unsupported
    case .expanded: return value.expanded.map(AXProbeValue.bool) ?? .unsupported
    case .value: return .string(value.value)
    case .count(let name):
      if name == "AXChildren" { return .integer(value.children.count) }
      if name == "AXVisibleChildren", let visible = value.visible { return .integer(visible.count) }
      return .unsupported
    case .page(let name, let start, let count):
      let list = name == "AXVisibleChildren" ? value.visible ?? [] : value.children
      return .nodes(Array(list.dropFirst(start).prefix(count)))
    case .characterCount: return .integer(value.value.utf16.count)
    case .visibleRange: return value.range.map { .range($0.0, $0.1) } ?? .unsupported
    case .substring(let start, let count): return .string((value.value as NSString).substring(with: NSRange(location: start, length: count)))
    default: return .unsupported
    }
  }
}
// Model metadata/value batches and paged children, with local cached scalar lookups.
private final class InventedBatchProvider: AXProbeProvider {
  let base: ProbeProvider
  var application: Int { base.application }
  var ipcCount: Int? { calls }
  var calls = 0, batches = 0
  var time = 100.0
  private var prepared = Set<Int>()
  init(_ base: ProbeProvider) { self.base = base }
  func prepare(_ node: Int, timeout: Double) -> AXProbeValue? {
    if prepared.insert(node).inserted { batches += 2; calls += 2; time += 0.008 }
    return nil
  }
  func releaseNode(_ node: Int) { prepared.remove(node) }
  func read(_ node: Int, _ attribute: AXProbeAttribute, timeout: Double) -> AXProbeValue {
    let page: Bool
    if case .page = attribute { page = true } else { page = false }
    if !prepared.contains(node) || page { calls += 1; time += 0.004 }
    return base.read(node, attribute, timeout: timeout)
  }
  func matchingWindows(_ request: WindowIdentity, frame: AXProbeFrame) -> Bool { true }
}
private func collected(_ result: AXProbeResult) -> String {
  (result.nodes ?? []).flatMap { $0.attributes.map(\.text) }.filter { !$0.isEmpty }.joined(separator: "\n")
}
final class AXProbeTests: XCTestCase {
  func testBootSessionKeepsOnlyASuccessfulRead() {
    let boot = FirstNonEmpty()
    var reads = ["", "invented-boot", "invented-other"]
    func read() -> String { reads.removeFirst() }
    XCTAssertEqual(boot.value(read), "")
    XCTAssertEqual(boot.value(read), "invented-boot")
    XCTAssertEqual(boot.value(read), "invented-boot")
    XCTAssertEqual(reads, ["invented-other"])
  }
  private let window = WindowIdentity(processID: 10, windowID: 20)
  func testPairRecordsObservedBrowserBooleanWithoutAppCategoriesAndDecodesLegacy() throws {
    for bundle in ["invented.editor", "invented.browser", "invented.unknown"] {
      for browser in [true, false] {
        for known in [true, false] {
          let request = AXProbeRequest(run: AXProbeRun(start: 100), time: 101, window: window,
            bundleID: bundle, isBrowser: browser, isBrowserKnown: known)
          let pair = AXProbePair(request: request, ax: AXProbeResult(), ocrStatus: "empty", ocr: "",
            imageRequest: nil, imageReturn: nil, ocrCompletion: 0)
          XCTAssertEqual(pair.isBrowser, known ? browser : nil)
          let encoded = try JSONEncoder().encode(pair)
          var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
          XCTAssertNil(json["category"])
          XCTAssertEqual(json["isBrowser"] as? Bool, known ? browser : nil)
          json.removeValue(forKey: "isBrowser")
          json["category"] = "invented_legacy_category"
          let decoded = try JSONDecoder().decode(AXProbePair.self, from: JSONSerialization.data(withJSONObject: json))
          XCTAssertNil(decoded.isBrowser)
          XCTAssertEqual(decoded.bundleID, bundle)
          let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [String: Any]
          XCTAssertNil(reencoded["category"])
        }
      }
    }
  }
  private func run(_ provider: ProbeProvider, permitted: @escaping () -> Bool = { true },
    now: @escaping () -> Double = { 100 }) -> AXProbeResult {
    AXProbeExtractor(provider: provider, permitted: permitted, now: now).acquire(window)
  }
  func testSecureRoleSubroleAndFlagKeepMetadataWithoutReadingValues() {
    for identity in ["role", "subrole", "flag"] {
      let p = ProbeProvider()
      p.nodes[2]?.role = identity == "role" ? "AXSecureTextField" : "AXTextField"
      p.nodes[2]?.subrole = identity == "subrole" ? "AXSecureTextField" : nil
      p.nodes[2]?.value = "InventedSecureFixture987654"
      p.nodes[2]?.range = (0, 8)
      p.before = { node, attribute in
        if node == 2 && attribute == .secure { return .bool(identity == "flag") }
        if node == 2 && attribute == .title { return .string("Invented secure label") }
        return nil
      }
      let result = run(p)
      XCTAssertEqual(result.nodes?.first { $0.nodeID == 2 }?.secure, true)
      XCTAssertEqual(result.counts["secure_fields"], 1)
      XCTAssertFalse(collected(result).contains("InventedSecureFixture987654"))
      XCTAssertTrue(collected(result).contains("Invented secure label"))
      XCTAssertFalse(p.reads.contains { node, attribute in
        guard node == 2 else { return false }
        switch attribute { case .value, .selectedText, .visibleRange, .substring: return true; default: return false }
      })
    }
  }
  func testInventedBatchNodeLatencyAndIPCReductionWithEqualContent() {
    func tree() -> ProbeProvider {
      let p = ProbeProvider()
      p.nodes[1]?.children = Array(2...100)
      for index in 2...100 { p.nodes[index] = ProbeNode() }
      return p
    }
    var clock = 100.0
    let sequential = tree()
    sequential.before = { _, _ in clock += 0.004; return nil }
    let old = run(sequential, now: { clock })
    let batch = InventedBatchProvider(tree())
    let new = AXProbeExtractor(provider: batch, permitted: { true }, now: { batch.time }).acquire(window)
    XCTAssertEqual(collected(old), collected(new)); XCTAssertEqual(new.status, .completed)
    XCTAssertEqual(new.elements, 100); XCTAssertEqual(batch.batches, 200)
    XCTAssertEqual(new.ipc, 204)
    let oldTimes = old.nodes!.compactMap(\.readSeconds).sorted()
    let newTimes = new.nodes!.compactMap(\.readSeconds).sorted()
    XCTAssertEqual(newTimes[49], 0.008, accuracy: 0.000001)
    XCTAssertEqual(newTimes[94], 0.008, accuracy: 0.000001)
    XCTAssertGreaterThan(oldTimes[49], newTimes[49] * 8)
    print("invented_ax_batch nodes=100 sequential_ipc=\(old.ipc) batch_ipc=\(new.ipc) sequential_p50=\(oldTimes[49]) sequential_p95=\(oldTimes[94]) batch_p50=\(newTimes[49]) batch_p95=\(newTimes[94]) sequential_wall=\(old.end-old.start) batch_wall=\(new.end-new.start)")
  }
  func testDroppedOCRKeepsAXInBackgroundPipelineWithContentFreeReason() {
    let request = AXProbeRequest(run: AXProbeRun(start: 100), time: 101, window: window, bundleID: "invented.editor", isBrowser: false)
    var ax = AXProbeResult(status: .completed); ax.text = "Invented AX"
    let pair = AXProbePair(request: request, ax: ax, ocrStatus: "completed", ocr: "Invented dropped OCR",
      imageRequest: nil, imageReturn: nil, ocrCompletion: 0)
    let done = expectation(description: "AX persisted without dropped OCR")
    let pipeline = AXProbePipeline(write: { saved, evidence, _, _ in
      XCTAssertEqual(saved.ax.text, "Invented AX"); XCTAssertEqual(saved.ocr, "")
      XCTAssertEqual(saved.ocr_refusal_reason, .dropped); XCTAssertNil(evidence); done.fulfill()
    }, dropped: { _ in XCTFail() })
    let receipt = pipeline.offer(pair, permitted: { true })!
    pipeline.refuseOCR(receipt, reason: .dropped)
    pipeline.commit(receipt, evidenceID: nil, at: 101)
    wait(for: [done], timeout: 1)
  }
  func testFullTreeWebHiddenTabForeignPIDAndOffscreenAreCollectedAndFlagged() {
    let p = ProbeProvider()
    p.nodes[1]?.children = [2, 5]
    p.nodes[2] = ProbeNode(role: "AXWebArea", children: [3])
    p.nodes[3] = ProbeNode(role: "AXTab", children: [4], hidden: true, expanded: false, selected: false)
    p.nodes[4] = ProbeNode(frame: AXProbeFrame(x: 900, y: 0, width: 10, height: 10), value: "Invented hidden tab text")
    p.nodes[5] = ProbeNode(role: "AXMenu", value: "Invented popup text")
    p.before = { node, attr in node == 4 && attr == .pid ? .integer(99) : nil }
    let result = run(p)
    XCTAssertEqual(result.status, .completed)
    XCTAssertTrue(collected(result).contains("Invented hidden tab text"))
    XCTAssertTrue(collected(result).contains("Invented popup text"))
    let child = result.nodes?.first { $0.nodeID == 4 }
    XCTAssertEqual(child?.pid, 99); XCTAssertEqual(child?.bundleID, "invented.bundle")
    XCTAssertEqual(child?.depth, 3); XCTAssertEqual(child?.insideWindow, false); XCTAssertEqual(child?.onScreen, false)
    XCTAssertEqual(child?.hiddenBranch, true); XCTAssertEqual(child?.collapsedBranch, true)
    XCTAssertEqual(child?.unselectedBranch, true); XCTAssertEqual(child?.nonSelectedTab, true)
    XCTAssertEqual(result.elements, 5)
  }
  func testRadioButtonTabBranchPropagatesNonSelectionWithoutPruning() {
    let p = ProbeProvider()
    p.nodes[2] = ProbeNode(role: "AXTabGroup", children: [3])
    p.nodes[3] = ProbeNode(role: "AXRadioButton", children: [4], selected: false)
    p.nodes[4] = ProbeNode(value: "Invented inactive tab")
    let result = run(p)
    XCTAssertTrue(collected(result).contains("Invented inactive tab"))
    XCTAssertEqual(result.nodes?.first { $0.nodeID == 4 }?.nonSelectedTab, true)
  }
  func testActiveTabDoesNotMarkVisibleUnselectedRowAsInactiveTab() {
    let p = ProbeProvider()
    p.nodes[2] = ProbeNode(role: "AXTabGroup", children: [3])
    p.nodes[3] = ProbeNode(role: "AXRadioButton", children: [4], selected: true)
    p.nodes[4] = ProbeNode(role: "AXRow", value: "Invented visible unselected row", expanded: true, selected: false)
    let result = run(p)
    let row = result.nodes?.first { $0.nodeID == 4 }
    XCTAssertEqual(row?.selected, false); XCTAssertEqual(row?.unselectedBranch, true)
    XCTAssertEqual(row?.nonSelectedTab, false); XCTAssertEqual(row?.hiddenBranch, false)
    XCTAssertTrue(collected(result).contains("Invented visible unselected row"))
  }
  func testHugeStringAndDisclosedRangeRecordOriginalLengthWithoutRangeAllocation() {
    let p = ProbeProvider()
    let huge = String(repeating: "h", count: AXProbeResources.stringUTF16 + 1)
    p.nodes[2] = ProbeNode(value: huge, range: (0, huge.utf16.count))
    let result = run(p)
    let attributes = result.nodes!.first { $0.nodeID == 2 }!.attributes
    XCTAssertEqual(attributes.map(\.originalLength), [huge.utf16.count, huge.utf16.count])
    XCTAssertTrue(attributes.allSatisfy { $0.resourceTruncated == true && $0.text.isEmpty })
    XCTAssertEqual(result.truncations?["resource_truncated"], 1)
    XCTAssertFalse(p.reads.contains { if case .substring = $0.1 { return true }; return false })
  }
  func testHugeMetadataKeepsEachOriginalLengthAsAnEmptyDiagnosticAttribute() {
    let p = ProbeProvider()
    let huge = String(repeating: "r", count: AXProbeResources.stringUTF16 + 1)
    p.nodes[2]?.role = huge; p.nodes[2]?.subrole = huge + "s"
    let result = run(p), node = result.nodes!.last!
    XCTAssertNil(node.role); XCTAssertNil(node.subrole)
    XCTAssertEqual(node.attributes.first { $0.attribute == "AXRole" }?.originalLength, huge.utf16.count)
    XCTAssertEqual(node.attributes.first { $0.attribute == "AXSubrole" }?.originalLength, huge.utf16.count + 1)
  }
  func testMalformedHugeRangesKeepExactPerAttributeLengthsWithoutCounterOverflow() {
    let p = ProbeProvider()
    p.nodes[1]?.range = (0, Int.max); p.nodes[2]?.range = (0, Int.max)
    let result = run(p)
    XCTAssertEqual(result.nodes?.map { $0.attributes.last?.originalLength }, [Int.max, Int.max])
    XCTAssertEqual(result.counts["resource_truncated_original_utf16"], Int.max)
    XCTAssertEqual(result.counts["resource_length_sum_overflow"], 1)
  }
  func testVisibleRangeIsChunkedWithoutSplittingSupplementaryScalar() {
    let p = ProbeProvider()
    let text = String(repeating: "a", count: AXProbeResources.rangeUTF16 - 1) + "😀" + String(repeating: "z", count: 20000)
    p.nodes[2] = ProbeNode(value: text, range: (0, text.utf16.count))
    p.before = { node, attr in
      guard node == 2, case .substring(let offset, let count) = attr else { return nil }
      var units = Array(text.utf16.dropFirst(offset).prefix(count))
      if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
      return .string(String(decoding: units, as: UTF16.self))
    }
    let result = run(p)
    XCTAssertEqual(result.nodes?.last?.attributes.last?.text, text)
    let sizes = p.reads.compactMap { _, attr -> Int? in if case .substring(_, let count) = attr { return count }; return nil }
    XCTAssertGreaterThan(sizes.count, 1); XCTAssertLessThanOrEqual(sizes.max()!, AXProbeResources.rangeUTF16)
  }
  func testDenseParentAggregatesDropOverloadedAttemptButStillWalkEveryNode() {
    let p = ProbeProvider()
    let large = String(repeating: "x", count: AXProbeResources.stringUTF16)
    p.nodes[1]?.children = Array(2...24)
    for index in 1...24 { p.nodes[index] = ProbeNode(value: large, children: index == 1 ? Array(2...24) : []) }
    let result = run(p)
    XCTAssertEqual(result.elements, 24); XCTAssertEqual(result.status, .overload_dropped)
    XCTAssertEqual(result.nodes, []); XCTAssertEqual(result.text, "")
    XCTAssertEqual(result.counts["overload_dropped"], 1)
    let request = AXProbeRequest(run: AXProbeRun(start: 100), time: 101, window: window, bundleID: "invented.bundle", isBrowser: false)
    let pair = AXProbePair(request: request, ax: result, ocrStatus: "empty", ocr: "", imageRequest: nil, imageReturn: nil, ocrCompletion: 0)
    let dropped = expectation(description: "dense attempt explicitly dropped by pipeline")
    let pipeline = AXProbePipeline(write: { _, _, _, _ in XCTFail("overloaded payload cannot persist") }, dropped: { _ in dropped.fulfill() })
    XCTAssertNil(pipeline.offer(pair, permitted: { true })); wait(for: [dropped], timeout: 5)
  }
  func testOverloadKeepsFatalIPCStatusForPIDProtectionAndStillDropsPayload() {
    for failure in [true, false] {
      let p = ProbeProvider()
      let large = String(repeating: "x", count: AXProbeResources.stringUTF16)
      for index in 1...24 { p.nodes[index] = ProbeNode(value: large, children: index == 1 ? Array(2...24) : []) }
      var clock = 100.0
      p.before = { node, attr in
        if node == 24 && attr == .role {
          if failure { return .failure(-25204) }
          clock = 116
        }
        return nil
      }
      let result = run(p, now: { clock })
      XCTAssertEqual(result.status, failure ? .messagingFailure : .deadline)
      XCTAssertEqual(result.counts["overload_dropped"], 1); XCTAssertEqual(result.nodes, [])
      let request = AXProbeRequest(run: AXProbeRun(start: 100), time: 101, window: window, bundleID: "invented.bundle", isBrowser: false)
      let pair = AXProbePair(request: request, ax: result, ocrStatus: "empty", ocr: "", imageRequest: nil, imageReturn: nil, ocrCompletion: 0)
      let dropped = expectation(description: "overload retained alongside IPC failure")
      let pipeline = AXProbePipeline(write: { _, _, _, _ in XCTFail("overloaded attempt must drop") }, dropped: { _ in dropped.fulfill() })
      XCTAssertNil(pipeline.offer(pair, permitted: { true })); wait(for: [dropped], timeout: 5)
    }
  }
  func testPipelineChargesExecutingInputUntilWriteFinishesAndDropsNewest() throws {
    let request = AXProbeRequest(run: AXProbeRun(start: 100), time: 101, window: window, bundleID: "invented.bundle", isBrowser: false)
    var pair = AXProbePair(request: request, ax: AXProbeResult(status: .completed), ocrStatus: "empty", ocr: "", imageRequest: nil, imageReturn: nil, ocrCompletion: 0)
    pair.ax.text = String(repeating: "Invented queued input ", count: 10000)
    let charge = AXProbeResources.bytes(pair)
    let writing = expectation(description: "input executing"), dropped = expectation(description: "newest dropped")
    let released = expectation(description: "all reservations released")
    let release = DispatchSemaphore(value: 0)
    let pipeline = AXProbePipeline(capacity: charge, write: { _, _, _, _ in
      writing.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
    }, dropped: { _ in dropped.fulfill() })
    let receipt = try XCTUnwrap(pipeline.offer(pair, permitted: { true }))
    pipeline.commit(receipt, evidenceID: nil, at: pair.time)
    wait(for: [writing], timeout: 5)
    XCTAssertEqual(pipeline.reservedBytes, charge)
    pair.attemptID = UUID().uuidString
    XCTAssertNil(pipeline.offer(pair, permitted: { true }))
    release.signal(); pipeline.drain { released.fulfill() }
    wait(for: [dropped, released], timeout: 5); XCTAssertEqual(pipeline.reservedBytes, 0)
  }
  func testPolicyCancellationAtEveryReadBoundaryClearsAllNodeText() {
    let baseline = ProbeProvider(); _ = run(baseline)
    for boundary in 1...baseline.reads.count {
      let p = ProbeProvider(); var count = 0
      let result = run(p, permitted: { count += 1; return count < boundary })
      XCTAssertEqual(result.status, .cancelled)
      XCTAssertEqual(collected(result), ""); XCTAssertEqual(result.nodes, [])
    }
  }
  func testFatalNativeFailureKeepsPartialTextAndActualError() {
    let p = ProbeProvider()
    p.before = { node, attr in node == 2 && attr == .role ? .failure(-25204) : nil }
    let result = run(p)
    XCTAssertEqual(result.status, .messagingFailure); XCTAssertEqual(result.error, -25204)
    XCTAssertTrue(collected(result).contains("Invented visible label"))
    XCTAssertEqual(result.truncations?["messagingFailure"], 1)
  }
  func testAllTextAttributesIncludingFullEditableValueAndVisibleRangeAreRead() {
    let p = ProbeProvider()
    p.nodes[2] = ProbeNode(role: "AXTextArea", value: "Visible invented hidden suffix", range: (0, 7))
    let attributes: [AXProbeAttribute] = [.title, .description, .help, .placeholder, .selectedText, .url, .document]
    p.before = { node, attr in node == 2 && attributes.contains(attr) ? .string("Invented attribute") : nil }
    let result = run(p)
    XCTAssertTrue(collected(result).contains("Visible invented hidden suffix"))
    let node = result.nodes!.first { $0.nodeID == 2 }!
    XCTAssertEqual(Set(node.attributes.map(\.attribute)), Set(["AXValue", "AXTitle", "AXDescription", "AXHelp", "AXPlaceholderValue", "AXSelectedText", "AXURL", "AXDocument", "AXStringForVisibleRange"]))
    XCTAssertEqual(node.attributes.last?.text, "Visible")
    XCTAssertTrue(p.timeouts.allSatisfy { $0 <= 0.050 })
  }
  func testVisibleRangeLongerThanOldChunkKeepsSupplementaryScalars() {
    let p = ProbeProvider()
    let text = String(repeating: "a", count: 1023) + "😀" + "Invented suffix"
    p.nodes[2] = ProbeNode(value: text, range: (0, text.utf16.count))
    let result = run(p)
    XCTAssertEqual(result.nodes?.first { $0.nodeID == 2 }?.attributes.last?.text, text)
    XCTAssertTrue(p.reads.contains { $0.0 == 2 && $0.1 == .substring(0, text.utf16.count) })
  }
  func testUnknownMetadataUnresolvedChildrenAndRepeatedContainmentKeepSiblingText() {
    let p = ProbeProvider()
    p.nodes[1]?.children = [2, 3, 2]
    p.nodes[2] = ProbeNode(role: "malformed", subrole: nil, frame: nil, value: "Invented unknown text", children: [1])
    p.nodes[3] = ProbeNode(value: "Invented sibling")
    p.before = { node, attr in node == 2 && attr == .count("AXChildren") ? .failure(-25200) : nil }
    let result = run(p)
    XCTAssertEqual(result.status, .completed)
    XCTAssertTrue(collected(result).contains("Invented unknown text")); XCTAssertTrue(collected(result).contains("Invented sibling"))
    XCTAssertEqual(result.elements, 3); XCTAssertEqual(result.nodes?.first { $0.nodeID == 2 }?.insideWindow, nil)
    XCTAssertNil(result.nodes?.first { $0.nodeID == 2 }?.collapsedBranch)
    XCTAssertEqual(result.counts["unresolved_children"], 1)
  }
  func testSecureFieldsAreRecordedAndTheirChildrenStillWalked() {
    let p = ProbeProvider()
    p.nodes[2] = ProbeNode(role: "AXSecureTextField", children: [3])
    p.nodes[3] = ProbeNode(value: "Invented child")
    p.before = { node, attr in node == 2 && attr == .value ? .unsupported : nil }
    let result = run(p)
    XCTAssertEqual(result.nodes?.first { $0.nodeID == 2 }?.secure, true)
    XCTAssertTrue(collected(result).contains("Invented child"))
    XCTAssertFalse(p.reads.contains { $0.0 == 2 && $0.1 == .value })
  }
  func testEmptyAttributesRemainMeasurableWithoutCreatingTextYield() {
    let p = ProbeProvider(); p.nodes[1]?.value = ""; p.nodes[2]?.value = ""
    let result = run(p)
    XCTAssertEqual(result.status, .empty); XCTAssertEqual(collected(result), "")
    XCTAssertEqual(result.nodes?.count, 2)
    XCTAssertEqual(result.nodes?.first?.attributes.first?.length, 0)
    let request = AXProbeRequest(run: AXProbeRun(start: 100), time: 101, window: window, bundleID: "invented.bundle", isBrowser: false)
    XCTAssertEqual(AXProbePair(request: request, ax: result, ocrStatus: "empty", ocr: "", imageRequest: nil,
      imageReturn: nil, ocrCompletion: 0).redacted().ax.text, "")
  }
  func testFullValueAndParentObservationsAreKeptWithoutDuplicateAggregate() {
    let p = ProbeProvider()
    p.nodes[1]?.value = "Invented aggregate"
    p.nodes[2]?.value = String(repeating: "invented ", count: 10000)
    let result = run(p)
    XCTAssertEqual(result.status, .completed); XCTAssertFalse(result.truncated)
    XCTAssertEqual(result.text, "")
    XCTAssertTrue(collected(result).hasPrefix("Invented aggregate")); XCTAssertGreaterThan(result.acquiredBytes, 65536)
  }
  func testDepthTruncationKeepsOtherBranchesAndCountsReason() {
    let p = ProbeProvider()
    p.nodes[1]?.children = [2, 1000]
    for node in 2...260 { p.nodes[node] = ProbeNode(value: "Invented depth", children: [node + 1]) }
    p.nodes[1000] = ProbeNode(value: "Invented sibling after depth limit")
    let result = run(p)
    XCTAssertTrue(result.truncated); XCTAssertEqual(result.truncations?["depthLimit"], 1)
    XCTAssertTrue(collected(result).contains("Invented sibling after depth limit"))
    XCTAssertEqual(result.nodes?.map(\.depth).max(), 256)
  }
  func testElementBudgetCountsExactlyFiftyThousandAndKeepsPartialText() {
    let p = ProbeProvider()
    p.nodes[1]?.children = Array(2...50001)
    p.before = { node, attr in
      guard node >= 2 else { return nil }
      switch attr {
      case .value: return .string("Invented leaf")
      case .pid: return .integer(10)
      default: return .unsupported
      }
    }
    let result = run(p)
    XCTAssertEqual(result.elements, 50000); XCTAssertEqual(result.nodes?.count, 50000)
    XCTAssertEqual(result.truncations?["elementLimit"], 1); XCTAssertFalse(collected(result).isEmpty)
  }
  func testDeadlineAtFifteenSecondsKeepsPartialTextAndCancellationClearsNodes() {
    let p = ProbeProvider(); var clock = 100.0
    p.before = { node, attr in if node == 2 && attr == .title { clock = 115 }; return nil }
    let result = run(p, now: { clock })
    XCTAssertEqual(result.status, .deadline); XCTAssertEqual(result.truncations?["deadline"], 1)
    XCTAssertFalse(collected(result).isEmpty)
    var allowed = true
    let cancelled = ProbeProvider()
    cancelled.before = { node, attr in if node == 2 && attr == .title { allowed = false }; return nil }
    let discarded = run(cancelled, permitted: { allowed })
    XCTAssertEqual(discarded.status, .cancelled); XCTAssertEqual(discarded.text, ""); XCTAssertEqual(discarded.nodes, [])
  }
  func testManualAccessibilityResultAndTargetWindowMatching() {
    for value in [AXProbeValue.bool(true), .bool(false), .unsupported, .failure(-25200)] {
      let p = ProbeProvider(); p.before = { _, attr in attr == .manualAccessibility ? value : nil }
      XCTAssertEqual(run(p).manualAccessibility, value == .bool(true) ? "set" : value == .failure(-25200) ? "failed" : "not_settable")
      XCTAssertEqual(p.reads.filter { $0.1 == .manualAccessibility }.count, 1)
    }
    let p = ProbeProvider(); p.matches = false
    let result = run(p)
    XCTAssertEqual(result.status, .completed); XCTAssertTrue(p.reads.contains { $0.1 == .value })
    XCTAssertEqual(result.identity, "focused_window_unverified")
    p.nodes[1]?.frame = nil
    let unknown = run(p)
    XCTAssertEqual(unknown.status, .completed)
    XCTAssertTrue(unknown.nodes!.allSatisfy { $0.insideWindow == nil })
  }
  func testNodeMaskingAndLengthsBeforePersistenceAndUnlimitedRun() throws {
    let p = ProbeProvider(); p.nodes[2]?.value = "password=inventedCredential password=anotherInventedCredential"
    let request = AXProbeRequest(run: AXProbeRun(start: 100), time: 101, window: window, bundleID: "invented.bundle", isBrowser: true)
    let pair = AXProbePair(request: request, ax: run(p), ocrStatus: "completed", ocr: "password=inventedOCR", imageRequest: nil, imageReturn: nil, ocrCompletion: 0).redacted()
    let text = pair.ax.nodes!.first { $0.nodeID == 2 }!.attributes.first!
    XCTAssertFalse(text.text.contains("inventedCredential")); XCTAssertEqual(text.maskHits["secret"], 2)
    XCTAssertEqual(text.length, text.text.unicodeScalars.count)
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(pair), as: UTF8.self).contains("inventedCredential"))
    XCTAssertEqual(request.run.start, 100)
    let legacy = try JSONDecoder().decode(AXProbeRun.self, from: Data(#"{"id":"invented-run","start":100,"expiry":86500,"browser":"exclude"}"#.utf8))
    XCTAssertEqual(legacy.start, 100)
  }
  func testStaleReviewFlagCannotPauseRestartedRecorder() {
    var settings = StorageSettings()
    settings.general["axProbe.reviewActive"] = "1"
    XCTAssertTrue(RecorderPolicy.recording(settings, at: 100))
  }

  func testReviewLeaseExpiresAcrossRestartSleepRollbackAndAbsoluteCap() throws {
    func lease(_ issued: Double, _ deadline: Double, start: Double = 100) throws -> AXProbeReviewLease {
      let json: [String: Any] = ["boot": "invented-boot", "sessionStart": start, "issued": issued,
        "deadline": deadline, "issuedWall": 1000, "deadlineWall": 1010]
      return try JSONDecoder().decode(AXProbeReviewLease.self, from: JSONSerialization.data(withJSONObject: json))
    }
    let active = try lease(100, 110)
    XCTAssertTrue(active.active(wall: 1001, continuous: 101, boot: "invented-boot"))
    XCTAssertFalse(active.active(wall: 1001, continuous: 110, boot: "invented-boot"))
    XCTAssertTrue(active.active(wall: 999, continuous: 101, boot: "invented-boot"))
    XCTAssertFalse(active.active(wall: 999, continuous: 110, boot: "invented-boot"))
    XCTAssertFalse(active.active(wall: 1001, continuous: 101, boot: "invented-reboot"))
    XCTAssertFalse(active.active(wall: 1001, continuous: 99, boot: "invented-boot"))
    XCTAssertFalse(try lease(1900, 1910).active(wall: 1001, continuous: 1901, boot: "invented-boot"))
    XCTAssertFalse(try lease(100, 111).active(wall: 1001, continuous: 101, boot: "invented-boot"))
  }
  func testGeometryToleranceAmbiguityNormalLayerAndRequestedID() {
    let frame = AXProbeFrame(x: -1200, y: -300, width: 800, height: 600)
    let one = AXProbeWindowCandidate(identity: window, layer: 0, frame: frame)
    let two = AXProbeWindowCandidate(identity: WindowIdentity(processID: 10, windowID: 21), layer: 0, frame: frame)
    XCTAssertTrue(AXProbeWindowMatching.matches(window, frame: frame, candidates: [one]))
    XCTAssertFalse(AXProbeWindowMatching.matches(window, frame: frame, candidates: [one, two]))
    XCTAssertFalse(AXProbeWindowMatching.matches(window, frame: frame, candidates: [two]))
    var moved = one; moved.frame.x += 2
    XCTAssertTrue(AXProbeWindowMatching.matches(window, frame: frame, candidates: [moved]))
    moved.frame.x += 0.01
    XCTAssertFalse(AXProbeWindowMatching.matches(window, frame: frame, candidates: [moved]))
    var popup = two; popup.layer = 1
    XCTAssertTrue(AXProbeWindowMatching.matches(window, frame: frame, candidates: [one, popup]))
  }
  func testVisibleRangeUTF16RejectsSplitAndInteriorInvalidSurrogates() {
    XCTAssertTrue(AXProbeUTF16.wellFormed([65, 0xD83D, 0xDE00, 66]))
    XCTAssertFalse(AXProbeUTF16.wellFormed([65, 0xD83D, 66]))
    XCTAssertFalse(AXProbeUTF16.wellFormed([65, 0xDE00, 66]))
    XCTAssertFalse(AXProbeUTF16.wellFormed([0xDE00, 66]))
    XCTAssertFalse(AXProbeUTF16.wellFormed([65, 0xD83D]))
  }

}
