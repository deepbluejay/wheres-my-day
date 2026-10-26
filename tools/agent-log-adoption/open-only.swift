import Foundation
@testable import Storage

let root = URL(fileURLWithPath: CommandLine.arguments[1])
for _ in 0..<2 {
  _ = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
    databaseScope: .directory(root))
}
