import SwiftUI
import AppKit
import ArchiveKit

/// 仿 Windows 7-Zip「解压」对话框。只做输入与实时反馈,不含解压逻辑;
/// 确认后把编辑好的 `ExtractOptions` 交回调用方。
struct ExtractOptionsView: View {
    let defaults: ExtractOptions
    let singleTopLevelDir: String?
    let isEncrypted: Bool
    let errorMessage: String?
    let onExtract: (ExtractOptions) -> Void
    let onCancel: () -> Void

    @State private var locationText: String
    @State private var subfolderEnabled: Bool
    @State private var subfolderName: String
    @State private var stripSingleTopDir: Bool
    @State private var overwriteMode: OverwritePolicy
    @State private var password: String
    @State private var showPassword = false

    init(defaults: ExtractOptions, singleTopLevelDir: String?, isEncrypted: Bool,
         errorMessage: String?, onExtract: @escaping (ExtractOptions) -> Void,
         onCancel: @escaping () -> Void) {
        self.defaults = defaults
        self.singleTopLevelDir = singleTopLevelDir
        self.isEncrypted = isEncrypted
        self.errorMessage = errorMessage
        self.onExtract = onExtract
        self.onCancel = onCancel
        _locationText = State(initialValue: defaults.location.path)
        _subfolderEnabled = State(initialValue: defaults.subfolderEnabled)
        _subfolderName = State(initialValue: defaults.subfolderName)
        _stripSingleTopDir = State(initialValue: defaults.stripSingleTopDir)
        _overwriteMode = State(initialValue: defaults.overwriteMode)
        _password = State(initialValue: defaults.password)
    }

    // MARK: Derived

    private var currentOptions: ExtractOptions {
        ExtractOptions(location: ExtractOptions.normalizeLocation(locationText),
                       subfolderEnabled: subfolderEnabled, subfolderName: subfolderName,
                       stripSingleTopDir: stripSingleTopDir, overwriteMode: overwriteMode,
                       password: password)
    }

    private var errors: [ExtractValidationError] { currentOptions.validate() }
    private var locationInvalid: Bool {
        errors.contains(.locationEmpty) || errors.contains(.locationNotADirectory)
            || errors.contains(.locationNotWritable)
    }
    private var subfolderInvalid: Bool { errors.contains(.invalidSubfolderName) }

    private var previewPath: String {
        (try? currentOptions.resolveDestination(singleTopLevelDir: singleTopLevelDir))?
            .finalFolder.path ?? "—"
    }
    private var willDump: Bool {
        subfolderEnabled && subfolderName.trimmingCharacters(in: .whitespaces).isEmpty
            || !subfolderEnabled
    }
    private var locationChanged: Bool { locationText != defaults.location.path }
    private var subfolderChanged: Bool { subfolderName != defaults.subfolderName }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("解压").font(.headline)

            locationRow
            subfolderRow

            Toggle("排除重复的根文件夹", isOn: $stripSingleTopDir)

            Picker("已存在时", selection: $overwriteMode) {
                Text("询问").tag(OverwritePolicy.ask)
                Text("解压到带序号文件夹").tag(OverwritePolicy.numbered)
                Text("删除原文件夹").tag(OverwritePolicy.deleteExisting)
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)

            passwordRow

            previewAndWarnings

            Divider()
            HStack {
                Spacer()
                Button("取消") { onCancel() }.keyboardShortcut(.cancelAction)
                Button("解压") { onExtract(currentOptions) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!errors.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: Rows

    private var locationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("解压位置").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("", text: $locationText)
                    .textFieldStyle(.roundedBorder)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(locationInvalid ? Color.red : Color.clear, lineWidth: 1))
                if locationChanged {
                    Button { locationText = defaults.location.path } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("还原默认")
                }
                Button("…") { browseForLocation() }
            }
        }
    }

    private var subfolderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle("到文件夹", isOn: $subfolderEnabled)
                    .toggleStyle(.checkbox)
                TextField("", text: $subfolderName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!subfolderEnabled)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(subfolderInvalid ? Color.red : Color.clear, lineWidth: 1))
                if subfolderChanged {
                    Button { subfolderName = defaults.subfolderName } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("还原默认")
                }
            }
        }
    }

    private var passwordRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("密码").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Group {
                    if showPassword {
                        TextField("", text: $password)
                    } else {
                        SecureField("", text: $password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                Toggle("显示密码", isOn: $showPassword).toggleStyle(.checkbox)
            }
        }
    }

    @ViewBuilder private var previewAndWarnings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("将解压到:\(previewPath)")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon")
                    .font(.caption).foregroundStyle(.red)
            }
            if subfolderInvalid {
                Label("文件夹名不能包含 / 或 :,也不能是 . 或 ..", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if locationInvalid {
                Label("解压位置必须是已存在且可写的目录", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if willDump && !locationInvalid {
                Label("文件将直接解压到该位置,可能覆盖同名文件", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Actions

    private func browseForLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = ExtractOptions.normalizeLocation(locationText)
        if panel.runModal() == .OK, let url = panel.url {
            locationText = url.path
        }
    }
}
