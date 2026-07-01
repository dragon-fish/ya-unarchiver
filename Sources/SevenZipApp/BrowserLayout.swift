import SwiftUI
import ArchiveKit

/// Abstraction so future layouts (breadcrumb, single outline) are drop-in.
protocol BrowserLayout: View {
    init(root: ArchiveNode, selection: Binding<ArchiveNode.ID?>)
}
