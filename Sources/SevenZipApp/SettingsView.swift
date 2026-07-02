import SwiftUI

/// The ⌘, settings pane. Currently one preference: what happens after an extraction.
struct SettingsView: View {
    @AppStorage("postExtractAction") private var postExtractAction: PostExtractAction = .revealInFinder

    var body: some View {
        Form {
            Picker("解压完成后", selection: $postExtractAction) {
                ForEach(PostExtractAction.allCases) { action in
                    Text(action.label).tag(action)
                }
            }
            .pickerStyle(.inline)
        }
        .padding(20)
        .frame(width: 360)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View { SettingsView() }
}
