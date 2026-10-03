import AppKit
import SwiftUI

/// Which editor font a `FontPickerButton` edits.
enum FontPickerTarget {
    /// Body text: `editorFontName` + `editorFontSize`.
    case prose
    /// Code: `editorMonoFontName` only; its size follows the body size.
    case monospace
}

/// A button that opens NSFontPanel and applies live updates to AppSettings.
/// As the user clicks fonts/sizes in the panel, `changeFont(_:)` fires immediately
/// and writes the target's settings, so the editor updates live.
struct FontPickerButton: NSViewRepresentable {
    let title: String
    var target: FontPickerTarget = .prose

    func makeNSView(context _: Context) -> FontPickerHostView {
        FontPickerHostView(title: title, target: target)
    }

    func updateNSView(_ nsView: FontPickerHostView, context _: Context) {
        nsView.button.title = title
    }
}

final class FontPickerHostView: NSView, NSFontChanging {
    let button: NSButton
    private let target: FontPickerTarget
    private var fontObserver: NSObjectProtocol?

    init(title: String, target: FontPickerTarget) {
        self.target = target
        button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.toolTip = L10n.shared[target == .prose ? "tooltip.font.choose" : "tooltip.font.chooseMono"]
        button.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: .zero)
        addSubview(button)
        button.target = self
        button.action = #selector(openPanel)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Keep the font panel's selection in sync with external changes
        // (e.g. user changes size via stepper while the panel is open).
        fontObserver = NotificationCenter.default.addObserver(
            forName: .editorFontChanged, object: nil, queue: .main,
        ) { [weak self] _ in
            // Only the picker the panel is editing for, so two pickers don't fight over it.
            guard let self, NSFontPanel.shared.isVisible, NSFontManager.shared.target === self else { return }
            NSFontManager.shared.setSelectedFont(currentFont, isMultiple: false)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    deinit {
        if let fontObserver {
            NotificationCenter.default.removeObserver(fontObserver)
        }
        // NSFontManager.target is unsafe_unretained — clear it so a stale
        // pointer can't crash if changeFont(_:) fires after this view is gone.
        if NSFontManager.shared.target === self {
            NSFontManager.shared.target = nil
        }
    }

    override var intrinsicContentSize: NSSize {
        button.intrinsicContentSize
    }

    private var currentFont: NSFont {
        switch target {
        case .prose: AppSettings.shared.editorFont
        case .monospace: AppSettings.shared.editorMonoFont
        }
    }

    @objc private func openPanel() {
        let manager = NSFontManager.shared
        manager.target = self
        manager.setSelectedFont(currentFont, isMultiple: false)
        let panel = NSFontPanel.shared
        panel.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    func changeFont(_ sender: NSFontManager?) {
        let current = currentFont
        let new = sender?.convert(current) ?? current
        switch target {
        case .prose:
            AppSettings.shared.editorFontName = new.fontName
            AppSettings.shared.editorFontSize = Double(new.pointSize)
        case .monospace:
            AppSettings.shared.editorMonoFontName = new.fontName
        }
    }

    /// Limit the font panel to family + size (no underline/strikethrough/color); the
    /// monospace font has no size of its own.
    func validModesForFontPanel(_: NSFontPanel) -> NSFontPanel.ModeMask {
        switch target {
        case .prose: [.face, .collection, .size]
        case .monospace: [.face, .collection]
        }
    }
}
