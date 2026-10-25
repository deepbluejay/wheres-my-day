// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "ActivityProbe",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "Core", plugins: ["ImportBoundary"]),
    .target(name: "Storage", dependencies: ["Core"], linkerSettings: [.linkedLibrary("sqlite3")], plugins: ["ImportBoundary"]),
    .target(name: "Inbound", dependencies: ["Core"], plugins: ["ImportBoundary"]),
    .target(name: "Outbound", dependencies: ["Core"], plugins: ["ImportBoundary"]),
    .target(name: "Shell", dependencies: ["Core", "Storage", "Inbound", "Outbound"], resources: [.copy("AgentCleanup")], plugins: ["ImportBoundary"]),
    .executableTarget(name: "agent-cleanup", dependencies: ["Shell"], path: "tools/agent-cleanup"),
    .executableTarget(name: "ActivityProbe", dependencies: ["Shell"], path: "Sources/AppEntry"),
    .executableTarget(name: "ConversationRender", dependencies: ["Core", "Shell"], path: "tools/conversation-render"),
    .executableTarget(name: "SettingsRender", dependencies: ["Core", "Shell"], path: "tools/settings-render"),
    .executableTarget(name: "MenuRender", dependencies: ["Core", "Shell"], path: "tools/menu-render"),
    .executableTarget(name: "WindowRender", dependencies: ["Core", "Shell"], path: "tools/window-render"),
    .executableTarget(name: "TimelineRender", dependencies: ["Core", "Shell"], path: "tools/timeline-render"),
    .executableTarget(name: "ActivityQueryServer", dependencies: ["Core", "Storage", "Shell"], path: "tools/activity-query-server"),
    .testTarget(name: "ChatTests", dependencies: ["Core", "Storage", "Inbound", "Outbound", "Shell"], path: "tests/ChatTests", exclude: ["Fixtures"]),
    .testTarget(name: "AgentCleanupTests", dependencies: ["Shell"], path: "tests/AgentCleanupTests"),
    .testTarget(name: "ShellTests", dependencies: ["Core", "Shell"], path: "tests/ShellTests"),
    .testTarget(name: "CoreTests", dependencies: ["Core"], path: "tests/CoreTests"),
    .testTarget(name: "StorageTests", dependencies: ["Core", "Storage"], path: "tests/StorageTests"),
    .testTarget(name: "RecorderTests", dependencies: ["Core", "Storage", "Shell", "Outbound", "Inbound"], path: "tests/RecorderTests"),
    .testTarget(name: "AgentLogTests", dependencies: ["Core", "Inbound", "Storage", "Shell"],
      path: "tests/AgentLogTests"),
    .executableTarget(name: "SummaryProbe", dependencies: ["Core", "Storage", "Shell", "Outbound"], path: "tools/summary-probe"),
    .plugin(name: "ImportBoundary", capability: .buildTool(), exclude: ["check.py", "test_check.py"]),
  ]
)
