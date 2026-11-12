import SwiftUI

/// 后台导入的进度条，挂在根视图上。
///
/// 导入改到后台以后，用户点完就能继续用别的：这里只负责告诉他
/// 「还在导 / 导完了 / 导挂了」，别让他以为没反应。
struct ImportBanner: View {
    @ObservedObject private var coordinator = ImportCoordinator.shared

    var body: some View {
        switch coordinator.state {
        case .idle:
            EmptyView()

        case .running(let title, _, _):
            card(
                title: String(format: L("Importing %@…"), title),
                detail: L("You can keep using the app while it finishes."),
                showsProgress: true,
                onDismiss: nil
            )

        case .done(let title, let count):
            card(
                title: String(format: L("Imported %d songs"), count),
                detail: title,
                showsProgress: false,
                onDismiss: { coordinator.clear() }
            )

        case .failed(let message):
            card(
                title: L("Import failed"),
                detail: message,
                showsProgress: false,
                onDismiss: { coordinator.clear() }
            )
        }
    }

    private func card(title: String, detail: String, showsProgress: Bool, onDismiss: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if showsProgress {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Theme.accent))
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryLabel)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let onDismiss = onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.secondaryLabel)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
