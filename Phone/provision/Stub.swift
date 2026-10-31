// Only exists so xcodebuild can mint the free provisioning profile; scripts/phone.sh builds the real app.
import SwiftUI

@main
struct Stub: App {
    var body: some Scene { WindowGroup { EmptyView() } }
}
