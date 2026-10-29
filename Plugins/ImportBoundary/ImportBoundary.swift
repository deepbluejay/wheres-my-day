import PackagePlugin

@main
struct ImportBoundary: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
    guard let source = target as? SourceModuleTarget else { return [] }
    let files = source.sourceFiles(withSuffix: "swift").map(\.path)
    // Modules of external package products count too, so an undeclared import of one is refused like a sibling's.
    let external = context.package.dependencies.flatMap { $0.package.products.flatMap { $0.targets.map(\.name) } }
    let modules = context.package.targets.map(\.name) + external
    let allowed = target.dependencies.flatMap { dependency -> [String] in
      switch dependency {
      case .target(let target): return [target.name]
      case .product(let product): return product.targets.map(\.name)
      @unknown default: return []
      }
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
