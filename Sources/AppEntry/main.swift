import Foundation
import Shell

// The stable entry shares one path context across recorder, window and command modes.
exit(ActivityProbeEntry.run(arguments: Array(CommandLine.arguments.dropFirst()),
  environment: ProcessInfo.processInfo.environment,
  userHome: FileManager.default.homeDirectoryForCurrentUser,
  appBinary: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL))
