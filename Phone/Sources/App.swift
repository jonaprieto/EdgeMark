import SwiftUI

@main
struct EdgeMarkPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup { RootView() }
            .onChange(of: phase) { _, now in
                // iOS gives no dependable background time, so sync on the way in and on the way out.
                switch now {
                case .active:
                    Task {
                        await PhoneModel.shared.calendars.refresh()
                        PhoneModel.shared.refresh()
                        await PhoneModel.shared.sync()
                        await PhoneModel.shared.refreshGists()
                    }
                case .background: PhoneModel.shared.syncBeforeSuspend()
                default: break
                }
            }
    }
}
