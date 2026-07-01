import SwiftUI
import AppKit
import ArchiveKit

struct AboutView: View {
    @State private var engineVersion = "…"

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("7zip-swiftui").font(.title2).bold()
            Text("版本 \(appVersion)").font(.caption).foregroundStyle(.secondary)
            Divider().frame(width: 180)
            Text("压缩引擎：7-Zip \(engineVersion)")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 300)
        .task { await loadEngineVersion() }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private func loadEngineVersion() async {
        let runner = SevenZipLocator.bundledRunner()
        engineVersion = await Task.detached { (try? runner.version()) ?? "不可用" }.value
    }
}
