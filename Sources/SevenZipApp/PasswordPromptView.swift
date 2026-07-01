import SwiftUI

struct PasswordPromptView: View {
    @Binding var password: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("此压缩包已加密").font(.headline)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(onSubmit)
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                Button("打开", action: onSubmit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
