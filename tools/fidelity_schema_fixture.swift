// Creates an empty invented database through the product's own schema code. It has
// no data and touches nothing outside the folder it is given.
import Foundation
@testable import Storage

let root = URL(fileURLWithPath: CommandLine.arguments[1])
_ = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
  databaseScope: .directory(root))
