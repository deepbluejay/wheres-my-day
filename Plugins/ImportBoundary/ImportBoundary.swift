import PackagePlugin

@main
struct ImportBoundary: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
    guard let source = target as? SourceModuleTarget else { return [] }
    let files = source.sourceFiles(withSuffix: "swift").map(\.path)
    let modules = context.package.targets.map(\.name)
    let allowed = target.dependencies.compactMap { dependency -> String? in
      if case .target(let target) = dependency { return target.name }
      return nil
    } + [target.name]
    let checker = context.package.directory.appending("Plugins/ImportBoundary/check.py")
    // A generated source makes SwiftPM run this command when an existing input changes.
    let output = context.pluginWorkDirectory.appending("CheckedImports.swift")
    return [.buildCommand(
      displayName: "Check \(target.name) imports against package dependencies",
      executable: Path("/usr/bin/python3"),
      arguments: [checker.string, target.name, modules.joined(separator: ","),
        allowed.joined(separator: ","), output.string] + files.map(\.string),
      inputFiles: files + [checker],
      outputFiles: [output])]
  }
}
