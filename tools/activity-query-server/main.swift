import Core
import Foundation
import Query
import Storage

let environment = ProcessInfo.processInfo.environment
guard ActivityQueryServer.leaseIsValid(environment: environment, at: Int(Date().timeIntervalSince1970)),
  let path = environment[QueryToolContract.databaseVariable],
  let appData = environment[QueryToolContract.appDataVariable], !appData.isEmpty else { exit(1) }
do {
  let url = URL(fileURLWithPath: path)
  let storage = try ActivityStorage(url: url, appDataDirectory: URL(fileURLWithPath: appData), readOnly: true, databaseScope: .directory(url.deletingLastPathComponent()))
  let server = ActivityQueryServer(queries: ActivityQueries(storage: storage), authorized: {
    ActivityQueryServer.leaseIsValid(environment: environment, at: Int(Date().timeIntervalSince1970))
  })
  server.serve()
} catch { exit(1) }
