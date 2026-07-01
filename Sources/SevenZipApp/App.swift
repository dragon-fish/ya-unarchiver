import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveKit

/// Configures and runs an `NSOpenPanel` for picking a single archive file.
/// Shared by the ⌘O menu command and the welcome-screen open button so the
/// panel setup lives in exactly one place. Returns the chosen URL, or nil if
/// the user cancels.
@MainActor
func presentArchiveOpenPanel() -> URL? {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    // Restrict to the archive UTTypes declared in Info.plist's CFBundleDocumentTypes.
    panel.allowedContentTypes = [
        "public.zip-archive",
        "org.7-zip.7-zip-archive",
        "com.rarlab.rar-archive",
        "public.tar-archive",
        "org.gnu.gnu-zip-archive",
        "public.archive",
    ].compactMap { UTType($0) }
    guard panel.runModal() == .OK else { return nil }
    return panel.url
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SevenZipSwiftUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(for: URL.self) { $url in
            Group {
                if let url {
                    ArchiveWindow(archiveURL: url)
                } else {
                    WelcomeView()
                }
            }
            // Spec §入口层: 处理 Finder 双击 / 拖到 Dock / `open` 传入的 open-file 事件，
            // 统一收敛为「打开一个 archive URL」。onOpenURL 是 SwiftUI 对该事件的原生入口。
            .onOpenURL { openWindow(value: $0) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开…") { openArchivePanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .appInfo) {
                Button("关于 YA Unarchiver") { openWindow(id: "about") }
            }
        }

        Window("关于 YA Unarchiver", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }

    private func openArchivePanel() {
        if let url = presentArchiveOpenPanel() {
            openWindow(value: url)
        }
    }
}

struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("把压缩包拖到这里，或").foregroundStyle(.secondary)
            Button("打开压缩包…") {
                if let url = presentArchiveOpenPanel() { openWindow(value: url) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(minWidth: 480, minHeight: 300)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            openWindow(value: url)
            return true
        }
    }
}

struct ArchiveWindow: View {
    let archiveURL: URL
    @StateObject private var model: ArchiveViewModel
    @State private var selection: ArchiveNode.ID?
    @State private var passwordDraft = ""
    @State private var showPasswordSheet = false
    @State private var collisionContinuation: CheckedContinuation<CollisionChoice, Never>?
    @State private var collisionURL: URL?
    @State private var isExtracting = false
    private let controller = ExtractionController(runner: SevenZipLocator.bundledRunner())

    init(archiveURL: URL) {
        self.archiveURL = archiveURL
        _model = StateObject(wrappedValue: ArchiveViewModel(archiveURL: archiveURL))
    }

    var body: some View {
        content
            .frame(minWidth: 720, minHeight: 460)
            .navigationTitle(archiveURL.lastPathComponent)
            .toolbar {
                ToolbarItemGroup {
                    Button { extractAll() } label: { Label("解压全部", systemImage: "arrow.down.doc") }
                        .disabled(isExtracting)
                    Button { extractSelected() } label: { Label("解压选中", systemImage: "arrow.down.square") }
                        .disabled(selection == nil || isExtracting)
                }
            }
            .onAppear { model.load() }
            .onChange(of: model.stateID) { _ in if case .needsPassword = model.state { showPasswordSheet = true } }
            .sheet(isPresented: $showPasswordSheet) {
                PasswordPromptView(
                    password: $passwordDraft,
                    onSubmit: { showPasswordSheet = false; model.load(password: passwordDraft) },
                    onCancel: { showPasswordSheet = false }
                )
            }
            .confirmationDialog(
                "目标文件夹已存在",
                isPresented: Binding(get: { collisionURL != nil }, set: { if !$0 { finishCollision(.cancel) } })
            ) {
                Button("解压到带序号的新文件夹") { finishCollision(.numbered) }
                Button("删除原文件夹再解压", role: .destructive) { finishCollision(.deleteExisting) }
                Button("取消", role: .cancel) { finishCollision(.cancel) }
            } message: {
                Text(collisionURL?.lastPathComponent ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading: ProgressView("正在读取…")
        case .loaded(let root): TwoPaneBrowserView(root: root, selection: $selection)
        case .needsPassword:
            VStack(spacing: 12) {
                Image(systemName: "lock.doc").font(.largeTitle)
                Button("输入密码") { showPasswordSheet = true }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            VStack { Image(systemName: "exclamationmark.triangle").font(.largeTitle); Text(message) }
                .foregroundStyle(.secondary).padding()
        }
    }

    private func extractAll() { runExtraction(selectedPaths: nil) }
    private func extractSelected() {
        guard let selection else { return }
        runExtraction(selectedPaths: [selection])
    }

    private func runExtraction(selectedPaths: [String]?) {
        guard !isExtracting else { return }
        isExtracting = true
        Task {
            defer { isExtracting = false }
            do {
                _ = try await controller.extract(
                    archive: archiveURL,
                    entries: model.lastEntries,
                    selectedPaths: selectedPaths,
                    password: model.password,
                    resolveCollision: { url in
                        await withCheckedContinuation { cont in
                            collisionContinuation = cont
                            collisionURL = url
                        }
                    }
                )
            } catch { /* CancellationError or extraction failure — surfaced via alert in a later polish pass */ }
        }
    }

    private func finishCollision(_ choice: CollisionChoice) {
        collisionURL = nil
        collisionContinuation?.resume(returning: choice)
        collisionContinuation = nil
    }
}
