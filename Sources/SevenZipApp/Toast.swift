import SwiftUI

/// One transient success toast: a message plus an "打开 Finder" action. Identity lets the
/// owning view cancel a stale auto-dismiss when a newer toast replaces it.
struct ToastState: Identifiable {
    let id = UUID()
    let message: String
    let folderURL: URL
}

/// Lightweight capsule overlay shown at the bottom of the archive window.
struct Toast: View {
    let message: String
    let onOpenFinder: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message)
            Button("打开 Finder", action: onOpenFinder)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 8)
    }
}
