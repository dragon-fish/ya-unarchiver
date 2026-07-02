import SwiftUI

/// Progress of an in-flight extraction. Starts `.indeterminate` (before any entry line
/// arrives, or when the archive never emits per-entry lines) and becomes `.determinate`
/// once real per-entry counts come in.
enum ExtractionProgressState: Equatable {
    case indeterminate
    case determinate(fraction: Double)
}

/// Dimmed, centered card shown over the archive window while an extraction runs.
/// Non-dismissable; there is no cancel affordance by design.
struct ExtractionProgressOverlay: View {
    let state: ExtractionProgressState

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 16) {
                switch state {
                case .indeterminate:
                    ProgressView().controlSize(.large)
                    Text("正在解压…")
                case .determinate(let fraction):
                    ProgressView(value: fraction).frame(width: 220)
                    Text("正在解压… \(Int(fraction * 100))%")
                }
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 20)
        }
    }
}

struct ExtractionProgressOverlay_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ExtractionProgressOverlay(state: .indeterminate)
            ExtractionProgressOverlay(state: .determinate(fraction: 0.45))
        }
    }
}
