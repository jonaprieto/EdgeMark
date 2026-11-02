import ActivityKit
import AppIntents
import SwiftUI

/// Control Center only opens an app whose own metadata lists the intent, so this file is compiled
/// into both the app and the widget extension.
struct DictateIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate"
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        // OpenURLIntent takes universal links only, and this one is a custom scheme.
        EnvironmentValues().openURL(URL(string: "edgemark://capture?kind=idea&voice=1")!)
        return .result()
    }
}

/// A take in progress, on the Lock Screen and CarPlay Dashboard. The timer needs nothing but its start.
struct DictationActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {}

    let started: Date
}
