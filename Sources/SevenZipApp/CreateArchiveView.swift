import SwiftUI
import AppKit
import ArchiveKit

/// 「创建压缩包」对话框。只做输入 + 实时反馈,不含压缩逻辑;确认后把编辑好的
/// CompressionOptions 交回调用方(仿 ExtractOptionsView)。
struct CreateArchiveView: View {
    let defaults: CompressionOptions
    let onCreate: (CompressionOptions) -> Void
    let onCancel: () -> Void

    @State private var outputDirText: String
    @State private var archiveName: String
    @State private var format: ArchiveFormat
    @State private var level: CompressionLevel
    @State private var password: String
    @State private var showPassword = false
    @State private var encryptHeader: Bool
    @State private var excludeDotfiles: Bool

    init(defaults: CompressionOptions, onCreate: @escaping (CompressionOptions) -> Void,
         onCancel: @escaping () -> Void) {
        self.defaults = defaults
        self.onCreate = onCreate
        self.onCancel = onCancel
        _outputDirText = State(initialValue: defaults.outputDirectory.path)
        _archiveName = State(initialValue: defaults.archiveName)
        _format = State(initialValue: defaults.format)
        _level = State(initialValue: defaults.level)
        _password = State(initialValue: defaults.password)
        _encryptHeader = State(initialValue: defaults.encryptHeader)
        _excludeDotfiles = State(initialValue: defaults.excludeDotfiles)
    }

    private var currentOptions: CompressionOptions {
        CompressionOptions(items: defaults.items,
                           outputDirectory: URL(fileURLWithPath: (outputDirText as NSString).expandingTildeInPath).standardizedFileURL,
                           archiveName: archiveName, format: format, level: level,
                           password: password, encryptHeader: encryptHeader,
                           excludeDotfiles: excludeDotfiles)
    }
    private var errors: [CompressionValidationError] { currentOptions.validate() }
    private var outputInvalid: Bool { errors.contains(.outputDirectoryInvalid) }
    private var nameInvalid: Bool { errors.contains(.invalidArchiveName) }
    private var previewPath: String { (try? currentOptions.resolveOutput())?.path ?? "—" }
    private var showHeaderToggle: Bool { format == .sevenZip && !password.isEmpty }
    private var outputChanged: Bool { outputDirText != defaults.outputDirectory.path }
    private var nameChanged: Bool { archiveName != defaults.archiveName }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("创建压缩包").font(.headline)
            Text("\(defaults.items.count) 项:\(defaults.items.map(\.lastPathComponent).joined(separator: "、"))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)

            outputRow
            nameRow

            Picker("格式", selection: $format) {
                Text("7z").tag(ArchiveFormat.sevenZip)
                Text("zip").tag(ArchiveFormat.zip)
            }
            .pickerStyle(.segmented).frame(maxWidth: 200, alignment: .leading)

            Picker("压缩等级", selection: $level) {
                Text("仅存储").tag(CompressionLevel.store)
                Text("最快").tag(CompressionLevel.fastest)
                Text("普通").tag(CompressionLevel.normal)
                Text("最好").tag(CompressionLevel.maximum)
                Text("极限").tag(CompressionLevel.ultra)
            }
            .pickerStyle(.menu).frame(maxWidth: 260, alignment: .leading)

            passwordRow
            if showHeaderToggle {
                Toggle("加密文件名/头", isOn: $encryptHeader)
            }
            Toggle("排除 dotfiles(.DS_Store 等)", isOn: $excludeDotfiles)

            previewAndWarnings

            Divider()
            HStack {
                Spacer()
                Button("取消") { onCancel() }.keyboardShortcut(.cancelAction)
                Button("创建") { onCreate(currentOptions) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!errors.isEmpty)
            }
        }
        .padding(20).frame(width: 480)
    }

    private var outputRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("保存到").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("", text: $outputDirText)
                    .textFieldStyle(.roundedBorder)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(outputInvalid ? Color.red : Color.clear, lineWidth: 1))
                if outputChanged {
                    Button { outputDirText = defaults.outputDirectory.path } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("还原默认")
                }
                Button("…") { browseForOutputDir() }
            }
        }
    }

    private var nameRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("压缩包名").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("", text: $archiveName)
                    .textFieldStyle(.roundedBorder)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(nameInvalid ? Color.red : Color.clear, lineWidth: 1))
                if nameChanged {
                    Button { archiveName = defaults.archiveName } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("还原默认")
                }
                Text(".\(format.fileExtension)").foregroundStyle(.secondary)
            }
        }
    }

    private var passwordRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("密码(留空=不加密)").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Group {
                    if showPassword { TextField("", text: $password) }
                    else { SecureField("", text: $password) }
                }
                .textFieldStyle(.roundedBorder)
                Toggle("显示密码", isOn: $showPassword).toggleStyle(.checkbox)
            }
        }
    }

    @ViewBuilder private var previewAndWarnings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("将创建:\(previewPath)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if nameInvalid {
                Label("压缩包名不能为空,且不能包含 / 或 :,也不能是 . 或 ..", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if outputInvalid {
                Label("保存位置无效:上层路径需为可写的目录", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func browseForOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (outputDirText as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { outputDirText = url.path }
    }
}
