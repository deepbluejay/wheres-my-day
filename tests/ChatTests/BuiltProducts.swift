import Foundation

/// The products of the build these tests run in. The test bundle sits in that build's bin folder, which through
/// tools/swiftpm test is the folder `tools/swiftpm build --show-bin-path` names. Never the debug link under .build: a
/// plain swift build repoints it at another build system's folder. A product missing there fails the test that runs it.
enum BuiltProducts {
  private final class Anchor {}

  static var folder: URL { Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent() }
  static var queryServer: URL { folder.appendingPathComponent("ActivityQueryServer") }
}
