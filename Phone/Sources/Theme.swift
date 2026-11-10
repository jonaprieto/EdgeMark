import EdgeStorageLogic
import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32) {
        let c = ColorTheme.components(hex)
        self.init(red: c.red, green: c.green, blue: c.blue)
    }
}

extension EnvironmentValues {
    /// The theme picked in Settings. Nil wears the system's own colors.
    @Entry var colorTheme: ColorTheme?
}

/// Where Settings keeps the pick, on this phone only.
enum ThemeSetting {
    static let key = "appearance.theme"
}

extension View {
    /// The window in `theme`: light or dark to match, and its accent. The style goes on the
    /// UIKit windows too, since a sheet is a presentation of its own.
    func themedWindow(_ theme: ColorTheme?) -> some View {
        environment(\.colorTheme, theme)
            .tint(theme.map { Color(hex: $0.palette.accent) })
            .onChange(of: theme, initial: true) {
                let style: UIUserInterfaceStyle = theme.map { $0.isDark ? .dark : .light } ?? .unspecified
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    for window in scene.windows {
                        window.overrideUserInterfaceStyle = style
                    }
                }
            }
    }

    /// Behind a List, Form or ScrollView: the theme's background in place of the system's.
    func themedBackground() -> some View {
        modifier(ThemedBackground())
    }
}

private struct ThemedBackground: ViewModifier {
    @Environment(\.colorTheme) private var theme

    func body(content: Content) -> some View {
        if let theme {
            content.scrollContentBackground(.hidden).background(Color(hex: theme.palette.background))
        } else {
            content
        }
    }
}

/// Tiles and cards: the theme's surface, else the system's.
struct Surface: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorTheme.map { Color(hex: $0.palette.surface) } ?? Color(.secondarySystemBackground)
    }
}
