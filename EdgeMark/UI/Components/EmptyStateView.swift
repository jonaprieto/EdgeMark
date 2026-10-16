import SwiftUI

/// Reusable empty state placeholder with icon, title, and subtitle.
struct EmptyStateView: View {
    let icon: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.panel(.headline))
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.panel(.caption1))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
