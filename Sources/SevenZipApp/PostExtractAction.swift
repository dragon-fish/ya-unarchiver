import Foundation

/// What to do after a successful extraction. Persisted via @AppStorage; user-configurable
/// in the Settings scene (⌘,). Default is `.revealInFinder`.
enum PostExtractAction: String, CaseIterable, Identifiable {
    case revealInFinder
    case notify
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .revealInFinder: return "打开 Finder"
        case .notify:         return "应用内提示"
        case .none:           return "不提示"
        }
    }
}
