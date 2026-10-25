import Foundation

/// Physical spelling for operations. Use FileLocation for grants and exclusions.
public enum CanonicalPath {
  public typealias Failure = FileLocation.Failure
  public static func resolve(_ url: URL) throws -> URL { try FileLocation.resolve(url) }
}
