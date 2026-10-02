import SwiftUI

/// 7 pt status dot: grey off, green idle, pulsing blue syncing, red conflict or error.
struct SyncStatusDot: View {
    let state: SyncState
    @State private var pulse = false

    private var color: Color {
        switch state {
        case .off: .gray.opacity(0.5)
        case .idle: .green
        case .syncing: .blue
        case .conflict, .error: .red
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(state == .syncing && pulse ? 0.3 : 1)
            .onChange(of: state == .syncing, initial: true) { _, syncing in
                withAnimation(syncing ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default) {
                    pulse = syncing
                }
            }
            .accessibilityLabel(state.summary)
    }
}
