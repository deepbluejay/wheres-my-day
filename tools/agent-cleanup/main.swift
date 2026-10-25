import Foundation
import Shell

exit(AgentCleanupCommand.run(Array(CommandLine.arguments.dropFirst())))
