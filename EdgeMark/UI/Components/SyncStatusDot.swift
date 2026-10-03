import SwiftUI

/// 7 pt status dot: grey off, green idle, orange pending, pulsing blue syncing, red
/// conflict, error, or files held back by the secrets guard.
struct SyncStatusDot: View {
    let state: SyncState
    private var color: Color {
        switch state {
        case .off: .gray.opacity(0.5)
        case .idle: .green
        case .pending: .orange
        case .syncing: .blue
        case .conflict, .error, .held: .red
        }
    }

    var body: some View {
        // Driven by the clock instead of a repeatForever animation, and paused unless syncing:
        // an idle paused TimelineView draws no frames, so the panel costs no CPU at rest.
        TimelineView(.animation(paused: state != .syncing)) { context in
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .opacity(state == .syncing ? Self.pulseOpacity(at: context.date) : 1)
        }
        .accessibilityLabel(state.summary)
    }

    /// Eases between 1 and 0.3 with a 1.4 s period.
    private static func pulseOpacity(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
        return 0.65 + 0.35 * cos(phase * 2 * .pi)
    }
}
