import Foundation
@testable import Storage

let root = URL(fileURLWithPath: CommandLine.arguments[1])
if CommandLine.arguments.last == "--refuse" {
  do {
    _ = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
      databaseScope: .directory(root))
    fatalError("Unsupported origin was accepted")
  } catch is StorageError {
    print("Unsupported origin refused")
  }
} else {
  for _ in 0..<2 {
    _ = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
      databaseScope: .directory(root))
  }
}
