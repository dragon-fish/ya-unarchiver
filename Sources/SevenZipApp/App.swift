import SwiftUI
import AppKit
import ArchiveKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct SevenZipSwiftUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @StateObject private var model: ArchiveViewModel

    init() {
        let debug = ProcessInfo.processInfo.environment["SEVENZIP_DEBUG_ARCHIVE"]
        let url = URL(fileURLWithPath: debug ?? "/dev/null")
        _model = StateObject(wrappedValue: ArchiveViewModel(archiveURL: url))
    }

    @State private var selection: ArchiveNode.ID?

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("正在读取…")
            case .loaded(let root):
                TwoPaneBrowserView(root: root, selection: $selection)
            case .needsPassword:
                Text("需要密码（Task 9 接入密码框）").foregroundStyle(.secondary)
            case .error(let message):
                VStack { Image(systemName: "exclamationmark.triangle"); Text(message) }
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { model.load() }
    }
}
