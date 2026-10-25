import SwiftUI

struct IdleSessionRemovalBanner: View {
    let count: Int
    let onCancel: () -> Void
    let onRemove: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: l10n["remove_idle_sessions_count"], count))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(l10n["remove_idle_sessions_confirm_help"])
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            action(l10n["remove_idle_sessions_cancel"], destructive: false, perform: onCancel)
            action(l10n["remove_idle_sessions_remove"], destructive: true, perform: onRemove)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(0.045))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5) }
        .onExitCommand(perform: onCancel)
        .accessibilityIdentifier("idleSessionRemovalBanner")
    }

    private func action(_ title: String, destructive: Bool, perform: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : .cancel, action: perform) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(destructive ? Color(red: 1, green: 0.6, blue: 0.55) : .white.opacity(0.8))
                .padding(.horizontal, 9)
                .frame(minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(destructive ? .red.opacity(0.14) : .white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }
}
