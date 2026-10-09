import AppKit
import Foundation

// MARK: - EdgeSide

enum EdgeSide: String {
    case left
    case right
}

/// Which screen edges open the panel. `both` arms the left and the right edge; the
/// panel then opens on the side that was touched.
enum EdgeChoice: String {
    case left
    case right
    case both
}

// MARK: - DismissalMode

/// How the panel dismisses.
/// - `.auto`: hide on mouse exit / click-outside / Space change (current behavior;
///   `isPanelPinned` still overrides all of those).
/// - `.toggle`: edge activation shows *and* sticks the panel; touching the activating
///   edge again dismisses it (after the activation-delay dwell, so a flick through the
///   edge doesn't kill the panel). Serves the copy-back-and-forth case without the pin
///   shortcut.
enum DismissalMode: String {
    case auto
    case toggle
}

// MARK: - AnimationStyle

enum AnimationStyle: String {
    /// Panel slides in/out from the screen edge (classic effect).
    /// On multi-monitor setups the slide travel may briefly appear on the adjacent display.
    case slide
    /// Panel fades in/out without any frame movement, so nothing ever appears on adjacent monitors.
    case fade
}

// MARK: - PanelSettings

/// Panel behavior + chrome: edge activation, dismissal, width, animation, and swipe
/// gestures. Split out of `ShortcutSettings` so each name matches its content. Plain
/// class (not `@Observable`); consumers snapshot into `@State` and observe notifications,
/// same pattern as `ShortcutSettings`. `isPanelPinned` is session-only (resets each
/// launch).
final class PanelSettings {
    static let shared = PanelSettings()

    /// Auto-hide when the mouse exits the panel.
    var autoHideOnMouseExit: Bool {
        didSet { UserDefaults.standard.set(autoHideOnMouseExit, forKey: autoHideKey) }
    }

    /// Delay (in seconds) before auto-hiding after mouse exit. 0 = immediate.
    var hideDelay: Double {
        didSet { UserDefaults.standard.set(hideDelay, forKey: hideDelayKey) }
    }

    /// Delay (in seconds) before edge activation triggers. 0 = immediate. Defaults to
    /// 0.15 so an overshoot toward a scroll bar does not open the panel.
    var activationDelay: Double {
        didSet { UserDefaults.standard.set(activationDelay, forKey: activationDelayKey) }
    }

    /// Dwell (in seconds) at the activating edge before a toggle-mode re-touch
    /// dismisses the panel. UI enforces a 0.05s floor so a brush across the edge
    /// can't instantly kill the panel. Show still uses `activationDelay`.
    var toggleDismissDelay: Double {
        didSet { UserDefaults.standard.set(toggleDismissDelay, forKey: toggleDismissDelayKey) }
    }

    /// Which screen edges open the panel.
    var edgeChoice: EdgeChoice {
        didSet {
            UserDefaults.standard.set(edgeChoice.rawValue, forKey: edgeSideKey)
            // Cross-post `shortcutSettingsChanged` so SidePanelController/PinButton
            // observers (which key off that name) reconfigure. Name cleanup deferred.
            NotificationCenter.default.post(name: .shortcutSettingsChanged, object: nil)
        }
    }

    /// Side the panel sits on: the chosen edge, or with `both` the edge touched last
    /// (right until one is touched; session-only).
    var edgeSide: EdgeSide {
        switch edgeChoice {
        case .left: .left
        case .right: .right
        case .both: lastTouchedSide
        }
    }

    private var lastTouchedSide: EdgeSide = .right

    /// Records the edge that was just touched, so with `both` the panel opens there.
    func noteTouchedSide(_ side: EdgeSide) {
        guard edgeChoice == .both, lastTouchedSide != side else { return }
        lastTouchedSide = side
        NotificationCenter.default.post(name: .shortcutSettingsChanged, object: nil)
    }

    /// Whether an edge shared by two displays also opens the panel. Off by default:
    /// the pointer does not stop there, so it takes a deliberate pause to trigger.
    var seamEdgesEnabled: Bool {
        didSet { UserDefaults.standard.set(seamEdgesEnabled, forKey: seamEdgesEnabledKey) }
    }

    /// How the panel dismisses — auto-hide or edge-toggle. See `DismissalMode`.
    var dismissalMode: DismissalMode {
        didSet {
            UserDefaults.standard.set(dismissalMode.rawValue, forKey: dismissalModeKey)
            NotificationCenter.default.post(name: .shortcutSettingsChanged, object: nil)
        }
    }

    /// Whether edge activation (mouse hover to trigger) is enabled.
    /// Open notes and folders with a single click. Shift/Command-click still multi-selects;
    /// off restores Finder-style select-then-double-click.
    var openOnSingleClick: Bool {
        didSet { UserDefaults.standard.set(openOnSingleClick, forKey: openOnSingleClickKey) }
    }

    var edgeActivationEnabled: Bool {
        didSet { UserDefaults.standard.set(edgeActivationEnabled, forKey: edgeActivationEnabledKey) }
    }

    /// Whether to exclude screen corners from edge activation.
    var excludeCorners: Bool {
        didSet { UserDefaults.standard.set(excludeCorners, forKey: excludeCornersKey) }
    }

    /// Whether clicking outside the panel hides it.
    var hideOnClickOutside: Bool {
        didSet { UserDefaults.standard.set(hideOnClickOutside, forKey: hideOnClickOutsideKey) }
    }

    /// When true, the panel ignores all auto-hide triggers (mouse exit, click-outside,
    /// Space change) and stays visible until explicitly dismissed via Escape or the
    /// global toggle shortcut. Useful when copy-pasting back and forth with another app.
    /// Session-only (resets each launch).
    var isPanelPinned: Bool {
        didSet {
            NotificationCenter.default.post(name: .panelPinStateChanged, object: nil)
        }
    }

    /// Whether swipe-right in header navigates back.
    var swipeToNavigateEnabled: Bool {
        didSet { UserDefaults.standard.set(swipeToNavigateEnabled, forKey: swipeToNavigateEnabledKey) }
    }

    /// Whether swipe left/right on editor navigates between notes.
    var editorSwipeToNavigateEnabled: Bool {
        didSet { UserDefaults.standard.set(editorSwipeToNavigateEnabled, forKey: editorSwipeToNavigateEnabledKey) }
    }

    /// Swipe sensitivity (0–1). Higher = smaller required swipe distance.
    var swipeGestureSensitivity: Double {
        didSet { UserDefaults.standard.set(swipeGestureSensitivity, forKey: swipeGestureSensitivityKey) }
    }

    /// Width of the side panel in points. Defaults to 671 on fresh installs; the
    /// drag handle and the settings slider still allow down to 400.
    var panelWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(panelWidth), forKey: panelWidthKey) }
    }

    /// Panel show/hide animation style.
    var animationStyle: AnimationStyle {
        didSet { UserDefaults.standard.set(animationStyle.rawValue, forKey: animationStyleKey) }
    }

    // MARK: - Keys

    private let autoHideKey = "autoHideOnMouseExit"
    private let hideDelayKey = "hideDelay"
    private let activationDelayKey = "activationDelay"
    private let toggleDismissDelayKey = "toggleDismissDelay"
    private let edgeSideKey = "edgeSide"
    private let seamEdgesEnabledKey = "seamEdgesEnabled"
    private let dismissalModeKey = "dismissalMode"
    private let edgeActivationEnabledKey = "edgeActivationEnabled"
    private let openOnSingleClickKey = "openOnSingleClick"
    private let excludeCornersKey = "excludeCorners"
    private let hideOnClickOutsideKey = "hideOnClickOutside"
    private let swipeToNavigateEnabledKey = "swipeToNavigateEnabled"
    private let editorSwipeToNavigateEnabledKey = "editorSwipeToNavigateEnabled"
    private let swipeGestureSensitivityKey = "swipeGestureSensitivity"
    private let panelWidthKey = "panelWidth"
    private let animationStyleKey = "animationStyle"

    // MARK: - Init

    private init() {
        autoHideOnMouseExit = UserDefaults.standard.object(forKey: autoHideKey) as? Bool ?? true
        hideDelay = UserDefaults.standard.object(forKey: hideDelayKey) as? Double ?? 0.5
        activationDelay = UserDefaults.standard.object(forKey: activationDelayKey) as? Double ?? 0.15
        toggleDismissDelay = UserDefaults.standard.object(forKey: toggleDismissDelayKey) as? Double ?? 0.3
        openOnSingleClick = UserDefaults.standard.object(forKey: openOnSingleClickKey) as? Bool ?? true

        if let raw = UserDefaults.standard.string(forKey: edgeSideKey),
           let choice = EdgeChoice(rawValue: raw)
        {
            edgeChoice = choice
        } else {
            edgeChoice = .right
        }
        seamEdgesEnabled = UserDefaults.standard.object(forKey: seamEdgesEnabledKey) as? Bool ?? false
        if let raw = UserDefaults.standard.string(forKey: dismissalModeKey),
           let mode = DismissalMode(rawValue: raw)
        {
            dismissalMode = mode
        } else {
            dismissalMode = .auto
        }
        edgeActivationEnabled = UserDefaults.standard.object(forKey: edgeActivationEnabledKey) as? Bool ?? true
        excludeCorners = UserDefaults.standard.object(forKey: excludeCornersKey) as? Bool ?? true
        hideOnClickOutside = UserDefaults.standard.object(forKey: hideOnClickOutsideKey) as? Bool ?? true
        isPanelPinned = false
        swipeToNavigateEnabled = UserDefaults.standard.object(forKey: swipeToNavigateEnabledKey) as? Bool ?? true
        editorSwipeToNavigateEnabled = UserDefaults.standard.object(forKey: editorSwipeToNavigateEnabledKey) as? Bool ?? true
        swipeGestureSensitivity = UserDefaults.standard.object(forKey: swipeGestureSensitivityKey) as? Double ?? 0.5

        if let raw = UserDefaults.standard.string(forKey: animationStyleKey),
           let style = AnimationStyle(rawValue: raw)
        {
            animationStyle = style
        } else {
            animationStyle = .slide
        }

        // Panel width (stored as Double since UserDefaults doesn't have CGFloat)
        let savedWidth = UserDefaults.standard.object(forKey: panelWidthKey) as? Double
        panelWidth = savedWidth.map { CGFloat($0) } ?? 671
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let panelPinStateChanged = Notification.Name("panelPinStateChanged")
}
