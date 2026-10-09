import Cocoa
import OSLog

/// Detects when the mouse reaches the screen edge and triggers panel activation.
final class EdgeDetector {
    /// Called when the user dwells at an armed edge long enough. Passes the screen and
    /// which of its edges was touched.
    var onEdgeActivated: ((NSScreen, EdgeSide) -> Void)?

    /// Dwell (seconds) to apply before firing `onEdgeActivated`. Defaults to
    /// `activationDelay`; `SidePanelController` overrides this to use the
    /// toggle-dismiss delay when the panel is already shown in Edge-toggle
    /// mode (a re-touch is a dismiss, not a show). Keeps edge detection
    /// decoupled from panel state — the policy lives in the controller.
    var activationDelayProvider: () -> Double = {
        PanelSettings.shared.activationDelay
    }

    /// True while the panel is shown. A seam then uses the narrow `edgeThreshold` band,
    /// so resting on the panel's own scroll bar next to the seam does not count as a
    /// re-touch that dismisses it.
    var isPanelShown: () -> Bool = { false }

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var lastHit: EdgeHit = .none
    private var activationTimer: Timer?
    private var isPaused = false
    private var isMenuOpen = false

    /// How close to the edge (in points) the cursor must be to trigger activation.
    private let edgeThreshold: CGFloat = 2

    /// Tolerance for treating two adjacent displays' edges as a shared seam
    /// (touching or near-touching) vs. a real gap. Two side-by-side displays
    /// placed with no gap share an exact edge; this absorbs sub-pixel rounding.
    private let seamTolerance: CGFloat = 2

    /// Width (in points) of the trigger band at a seam between two displays. Wider than
    /// `edgeThreshold` because the pointer is not stopped there and has to be parked.
    private let seamBand: CGFloat = 8

    /// Shortest dwell (seconds) at a seam, so crossing to the next display never triggers.
    private let seamDwell: Double = 0.3

    /// Height (in points) of corner exclusion zones to avoid macOS hot-corner conflicts.
    private let cornerExclusion: CGFloat = 50

    // MARK: - Public

    func startMonitoring() {
        guard globalMouseMonitor == nil else { return }
        Log.window.info("[EdgeDetector] started monitoring")
        // Global monitor: fires for mouse moves in OTHER apps' windows.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMove()
        }
        // Local monitor: fires for mouse moves in OUR app (covers the case
        // where EdgeMark is still the active app after the panel hides).
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMove()
            return event
        }
    }

    /// Pause detection during hide animation to prevent the race condition
    /// where a `mouseMoved` event during the animation re-sets `wasAtEdge`
    /// while `showPanel` is blocked by `isAnimating`.
    func pauseDetection() {
        isPaused = true
        cancelActivation()
        Log.window.debug("[EdgeDetector] paused")
    }

    /// Resume detection after animation completes. Sets `wasAtEdge` based on
    /// current mouse position so the user must leave-and-return to re-trigger.
    /// No-op if the menu bar menu is currently open.
    func resumeDetection() {
        guard !isMenuOpen else {
            Log.window.debug("[EdgeDetector] resume skipped — menu open")
            return
        }
        Log.window.debug("[EdgeDetector] resumed")
        isPaused = false
        let mouseLocation = NSEvent.mouseLocation
        if let screen = screenForPoint(mouseLocation) {
            lastHit = edgeHit(mouseLocation: mouseLocation, screen: screen)
        } else {
            lastHit = .none
        }
    }

    func menuWillOpen() {
        isMenuOpen = true
        pauseDetection()
    }

    func menuDidClose() {
        isMenuOpen = false
        resumeDetection()
    }

    func stopMonitoring() {
        Log.window.info("[EdgeDetector] stopped monitoring")
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
        cancelActivation()
    }

    // MARK: - Detection

    private func handleMouseMove() {
        guard !isPaused else { return }
        let t0 = CACurrentMediaTime()
        let mouseLocation = NSEvent.mouseLocation

        guard let screen = screenForPoint(mouseLocation) else { return }
        let hit = edgeHit(mouseLocation: mouseLocation, screen: screen)

        if case let .trigger(side, seam) = hit, hit != lastHit {
            // Just arrived at a trigger edge — start activation delay
            let delay = seam ? max(activationDelayProvider(), seamDwell) : activationDelayProvider()
            if delay <= 0 {
                Log.window.debug("[EdgeDetector] edge hit — immediate activation")
                onEdgeActivated?(screen, side)
            } else {
                Log.window.debug("[EdgeDetector] edge hit — activation timer (\(delay)s)")
                startActivation(delay: delay, screen: screen, side: side)
            }
        } else if !hit.isTrigger, lastHit.isTrigger {
            Log.window.debug("[EdgeDetector] left edge — cancelled")
            cancelActivation()
        }

        // Discriminating log: cursor reached the configured side's edge but
        // it's between two displays — not a desktop boundary, so no trigger.
        // Lets Console.app prove the gate fired (vs. the cursor just not
        // being near any edge). Fires once per arrival, not per mouseMove.
        if hit == .interior, lastHit != .interior {
            Log.window.debug("[EdgeDetector] interior edge ignored — not a desktop boundary")
        }

        lastHit = hit

        let elapsed = (CACurrentMediaTime() - t0) * 1000
        if elapsed > 2 {
            Log.window.warning("[EdgeDetector] handleMouseMove took \(String(format: "%.1f", elapsed))ms")
        }
    }

    /// Find the screen containing the point. Uses inclusive bounds (`<=` for
    /// maxX/maxY) so the cursor at the exact screen edge is still matched.
    private func screenForPoint(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            let f = screen.frame
            return point.x >= f.minX && point.x <= f.maxX
                && point.y >= f.minY && point.y <= f.maxY
        }
    }

    /// Result of an edge check:
    /// - `none`: cursor not at an armed edge (or corner-excluded).
    /// - `interior`: at an armed side's edge, but it lies *between* two displays and
    ///   seam edges are off, so it must not trigger.
    /// - `trigger`: at an edge that opens the panel, with its side. `seam` is true for
    ///   an edge between two displays, which needs a longer dwell.
    enum EdgeHit: Equatable {
        case none
        case interior
        case trigger(EdgeSide, seam: Bool)

        var isTrigger: Bool {
            if case .trigger = self {
                return true
            }
            return false
        }
    }

    /// Returns the edge state for the cursor, checking each armed side. A display's
    /// edge is a seam when another display sits on the other side of it at an
    /// overlapping y-range; offset and vertically-stacked layouts are handled, since
    /// an edge with no neighbor beside it is a desktop boundary even if it isn't the
    /// global x-extreme. A seam triggers only when `seamEdgesEnabled` is on, in a wider
    /// band, because moving the mouse from one display to another shouldn't pop the
    /// panel on the display you're leaving.
    private func edgeHit(mouseLocation: NSPoint, screen: NSScreen) -> EdgeHit {
        let settings = PanelSettings.shared
        guard settings.edgeActivationEnabled else { return .none }

        let visibleFrame = screen.visibleFrame
        let sides: [EdgeSide] = switch settings.edgeChoice {
        case .left: [.left]
        case .right: [.right]
        case .both: [.left, .right]
        }

        var sawInterior = false
        for side in sides {
            let seam = side == .right ? rightEdgeIsInterior(screen) : leftEdgeIsInterior(screen)
            let band = seam && !isPanelShown() ? seamBand : edgeThreshold
            let atSideEdge = side == .right
                ? mouseLocation.x >= visibleFrame.maxX - band
                : mouseLocation.x <= visibleFrame.minX + band
            guard atSideEdge else { continue }
            if seam, !settings.seamEdgesEnabled {
                sawInterior = true
                continue
            }

            // Corner exclusion: skip if cursor is within cornerExclusion of screen corners
            if settings.excludeCorners {
                let distFromBottom = mouseLocation.y - visibleFrame.minY
                let distFromTop = visibleFrame.maxY - mouseLocation.y
                if distFromBottom < cornerExclusion || distFromTop < cornerExclusion {
                    return .none
                }
            }
            return .trigger(side, seam: seam)
        }
        return sawInterior ? .interior : .none
    }

    /// True if another screen's left edge sits at this screen's right edge
    /// with an overlapping y-range — the seam you cross when moving the
    /// cursor from this display to the one on its right.
    private func rightEdgeIsInterior(_ screen: NSScreen) -> Bool {
        let s = screen.frame
        return NSScreen.screens.contains { other in
            guard other !== screen else { return false }
            let o = other.frame
            let leftEdgeAtOurRight = abs(o.minX - s.maxX) <= seamTolerance
            let yOverlap = min(o.maxY, s.maxY) - max(o.minY, s.minY) > seamTolerance
            return leftEdgeAtOurRight && yOverlap
        }
    }

    /// Symmetric to `rightEdgeIsInterior` for the left edge.
    private func leftEdgeIsInterior(_ screen: NSScreen) -> Bool {
        let s = screen.frame
        return NSScreen.screens.contains { other in
            guard other !== screen else { return false }
            let o = other.frame
            let rightEdgeAtOurLeft = abs(o.maxX - s.minX) <= seamTolerance
            let yOverlap = min(o.maxY, s.maxY) - max(o.minY, s.minY) > seamTolerance
            return rightEdgeAtOurLeft && yOverlap
        }
    }

    // MARK: - Activation Timer

    private func startActivation(delay: Double, screen: NSScreen, side: EdgeSide) {
        cancelActivation()
        activationTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.onEdgeActivated?(screen, side)
        }
    }

    private func cancelActivation() {
        activationTimer?.invalidate()
        activationTimer = nil
    }

    deinit {
        stopMonitoring()
    }
}
