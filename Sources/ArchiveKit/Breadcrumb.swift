import Foundation

/// One clickable step in the right-pane breadcrumb bar.
public struct BreadcrumbSegment: Equatable, Sendable {
    /// Display name (last path component).
    public let name: String
    /// Full node id (cumulative path) this segment navigates to.
    public let id: String
    public init(name: String, id: String) {
        self.name = name
        self.id = id
    }
}

/// Derives breadcrumb segments from a node's full path id (the tree uses a
/// "/"-joined path as its id; "" is the root). The root is NOT included — the
/// UI renders it separately.
public enum Breadcrumb {
    public static func segments(forPath path: String) -> [BreadcrumbSegment] {
        let components = path.split(separator: "/").map(String.init)
        var result: [BreadcrumbSegment] = []
        var accumulated = ""
        for component in components {
            accumulated = accumulated.isEmpty ? component : accumulated + "/" + component
            result.append(BreadcrumbSegment(name: component, id: accumulated))
        }
        return result
    }
}
