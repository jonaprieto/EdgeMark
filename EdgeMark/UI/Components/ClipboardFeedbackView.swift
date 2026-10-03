import SwiftUI

/// Toast capsule. Shows "Path copied" for `count` paths, or `text` when set; an error
/// gets a warning icon and red text.
struct ClipboardFeedbackView: View {
    @Environment(L10n.self) private var l10n

    var count = 1
    var text: String?
    var isError = false

    private var message: String {
        if let text { return text }
        return count == 1 ? l10n["feedback.copiedPath"] : l10n.t("feedback.copiedPaths", "\(count)")
    }

    var body: some View {
        Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .accessibilityLabel(message)
    }
}

/// A one-line message shown briefly at the bottom of the panel (gist publish result).
@Observable
final class FeedbackToast {
    static let shared = FeedbackToast()

    private(set) var message: (text: String, isError: Bool)?
    private var generation = 0

    /// Shows `text` for 2 s, or 4 s for an error; a newer message replaces it.
    func show(_ text: String, isError: Bool = false) {
        generation += 1
        let current = generation
        message = (text, isError)
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 4 : 2)) { [weak self] in
            guard self?.generation == current else { return }
            self?.message = nil
        }
    }
}
