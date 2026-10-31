import SwiftUI

@main
struct EdgeMarkPhoneApp: App {
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup { NotesRoot() }
            .onChange(of: phase) { _, now in
                // iOS gives no dependable background time, so sync on the way in and on the way out.
                switch now {
                case .active: Task { await PhoneModel.shared.sync() }
                case .background: PhoneModel.shared.syncBeforeSuspend()
                default: break
                }
            }
    }
}
