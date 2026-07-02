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

/// Tracks whether the current launch is servicing an open-file event, so the
/// default (nil-value) WindowGroup window can dismiss itself instead of showing
/// the welcome screen when Finder/`open`/drag launched us with an archive.
@MainActor
final class LaunchModel: ObservableObject {
    var openedViaFile = false
}

@main
struct SevenZipSwiftUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var launch = LaunchModel()

    var body: some Scene {
        WindowGroup(for: URL.self) { $url in
            Group {
                if let url {
                    ArchiveWindow(archiveURL: url)
                } else {
                    // The default window SwiftUI always creates at launch carries a
                    // nil value. On a file launch it is redundant (onOpenURL opens a
                    // real archive window), so this placeholder dismisses it; on a
                    // plain launch it shows the welcome screen instead.
                    LaunchPlaceholderView()
                }
            }
            .environmentObject(launch)
            // Spec §入口层: 处理 Finder 双击 / 拖到 Dock / `open` 传入的 open-file 事件，
            // 统一收敛为「打开一个 archive URL」。onOpenURL 是 SwiftUI 对该事件的原生入口。
            .onOpenURL { url in
                launch.openedViaFile = true
                openWindow(value: url)
            }
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

        Settings {
            SettingsView()
        }
    }

    private func openArchivePanel() {
        if let url = presentArchiveOpenPanel() {
            openWindow(value: url)
        }
    }
}

/// Content of the launch/default window. Waits a moment for an open-file event:
/// if one arrives, this window is a redundant launch artifact and dismisses
/// itself; otherwise it becomes the welcome screen.
struct LaunchPlaceholderView: View {
    @EnvironmentObject private var launch: LaunchModel
    @Environment(\.dismiss) private var dismiss
    @State private var showWelcome = false

    var body: some View {
        Group {
            if showWelcome {
                WelcomeView()
            } else {
                Color.clear
            }
        }
        .task {
            // Poll briefly for an open-file event (onOpenURL fires around launch).
            for _ in 0..<10 {
                if launch.openedViaFile { break }
                try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
            }
            if launch.openedViaFile {
                launch.openedViaFile = false  // reset so later windows still welcome
                dismiss()
            } else {
                showWelcome = true
            }
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
    @StateObject private var previewService: PreviewService
    @State private var selection: Set<ArchiveNode.ID> = []
    @State private var passwordDraft = ""
    @State private var showPasswordSheet = false
    @State private var collisionContinuation: CheckedContinuation<CollisionChoice, Never>?
    @State private var collisionURL: URL?
    @State private var isExtracting = false
    @State private var toast: ToastState?
    @State private var passwordError: String?
    @State private var extractError: String?
    @State private var extractPassword: String?   // password confirmed for extraction, overrides model.password
    private enum PasswordContext { case unlock, retryExtraction(selectedPaths: [String]?) }
    @State private var passwordContext: PasswordContext = .unlock
    @AppStorage("postExtractAction") private var postExtractAction: PostExtractAction = .revealInFinder
    private let controller = ExtractionController(runner: SevenZipLocator.bundledRunner())

    init(archiveURL: URL) {
        self.archiveURL = archiveURL
        _model = StateObject(wrappedValue: ArchiveViewModel(archiveURL: archiveURL))
        _previewService = StateObject(wrappedValue: PreviewService(
            archiveURL: archiveURL,
            runner: SevenZipLocator.bundledRunner()
        ))
    }

    var body: some View {
        content
            .frame(minWidth: 720, minHeight: 460)
            .navigationTitle(archiveURL.lastPathComponent)
            .overlay(alignment: .bottom) {
                if let toast {
                    Toast(message: toast.message,
                          onOpenFinder: { NSWorkspace.shared.activateFileViewerSelecting([toast.folderURL]) })
                        .padding(.bottom, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    Button { extractAll() } label: { Label("解压全部", systemImage: "arrow.down.doc") }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderedProminent)
                        .disabled(isExtracting)
                        .help("解压整个压缩包")
                    Button { extractSelected(selection) } label: { Label("解压选中", systemImage: "arrow.down.square") }
                        .disabled(selection.isEmpty || isExtracting)
                        .help("解压当前选中的项目")
                }
            }
            .onAppear { model.load() }
            .onChange(of: model.stateID) { _, _ in
                if case .needsPassword = model.state { showPasswordSheet = true }
                if case .loaded = model.state { previewService.password = model.password }
            }
            .sheet(isPresented: $showPasswordSheet) {
                PasswordPromptView(
                    password: $passwordDraft,
                    errorMessage: passwordError,
                    onSubmit: {
                        showPasswordSheet = false
                        let entered = passwordDraft
                        passwordError = nil
                        switch passwordContext {
                        case .unlock:
                            model.load(password: entered)
                        case .retryExtraction(let paths):
                            extractPassword = entered
                            previewService.password = entered
                            runExtraction(selectedPaths: paths)
                        }
                        passwordContext = .unlock
                    },
                    onCancel: {
                        showPasswordSheet = false
                        passwordError = nil
                        passwordContext = .unlock
                    }
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
            .alert("解压失败", isPresented: Binding(get: { extractError != nil }, set: { if !$0 { extractError = nil } })) {
                Button("好", role: .cancel) { extractError = nil }
            } message: {
                Text(extractError ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading: ProgressView("正在读取…")
        case .loaded(let root):
            TwoPaneBrowserView(
                root: root,
                selection: $selection,
                previewService: previewService,
                onExtractSelected: { ids in extractSelected(ids) }
            )
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
    private func extractSelected(_ ids: Set<ArchiveNode.ID>) {
        guard !ids.isEmpty else { return }
        runExtraction(selectedPaths: Array(ids))
    }

    private func runExtraction(selectedPaths: [String]?) {
        guard !isExtracting else { return }
        isExtracting = true
        Task {
            defer { isExtracting = false }
            do {
                let dest = try await controller.extract(
                    archive: archiveURL,
                    entries: model.lastEntries,
                    selectedPaths: selectedPaths,
                    password: extractPassword ?? model.password,
                    resolveCollision: { url in
                        await withCheckedContinuation { cont in
                            collisionContinuation = cont
                            collisionURL = url
                        }
                    }
                )
                switch postExtractAction {
                case .revealInFinder:
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                case .notify:
                    showToast(message: "已解压到 \(dest.lastPathComponent)", folderURL: dest)
                case .none:
                    break
                }
            } catch is CancellationError {
                // user cancelled the collision dialog — stay silent
            } catch ArchiveError.wrongPassword {
                passwordDraft = ""
                passwordError = "密码错误，请重试"
                passwordContext = .retryExtraction(selectedPaths: selectedPaths)
                showPasswordSheet = true
            } catch {
                extractError = "\(error)"
            }
        }
    }

    private func finishCollision(_ choice: CollisionChoice) {
        collisionURL = nil
        collisionContinuation?.resume(returning: choice)
        collisionContinuation = nil
    }

    private func showToast(message: String, folderURL: URL) {
        let state = ToastState(message: message, folderURL: folderURL)
        withAnimation { toast = state }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // 4s auto-dismiss
            if toast?.id == state.id { withAnimation { toast = nil } }
        }
    }
}
