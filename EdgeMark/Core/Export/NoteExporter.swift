import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// "Export as Markdown" and "Export as PDF" for a single note. Writes a copy chosen through
/// a save panel and never touches the note itself or its asset folder.
@MainActor
enum NoteExporter {
    private static let lastDirectoryKey = "export.lastDirectory"
    private static let pageMargin: CGFloat = 54

    // MARK: - Markdown

    /// Save the note's text as a standalone `.md`. Images from the note's asset folder are
    /// copied next to it into `<exported stem>-images/` and the links rewritten to match.
    static func exportMarkdown(note: Note, noteStore: NoteStore) {
        let current = currentNote(note, noteStore: noteStore)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = savedFilename(of: current)
        panel.directoryURL = lastDirectory
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                rememberDirectory(of: url)
                do {
                    try writeMarkdown(current, to: url)
                    Log.storage.info("[Export] wrote Markdown to \(url.path, privacy: .public)")
                } catch {
                    fail("Markdown", error)
                }
            }
        }
    }

    private static func writeMarkdown(_ note: Note, to url: URL) throws {
        let fm = FileManager.default
        let stem = (savedFilename(of: note) as NSString).deletingPathExtension
        let exportedStem = url.deletingPathExtension().lastPathComponent
        let rewritten = ExportLinks.rewriteImageLinks(in: note.content, stem: stem, exportedStem: exportedStem)

        // Copy the images first so a failure leaves no .md pointing at missing files.
        if !rewritten.imageNames.isEmpty {
            let source = FileStorage.assetDirURL(stem: stem, folder: note.folder)
            let target = url.deletingLastPathComponent()
                .appendingPathComponent("\(exportedStem)-images", isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for name in rewritten.imageNames {
                let from = source.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else {
                    Log.storage.error("[Export] referenced image missing: \(name, privacy: .public)")
                    continue
                }
                let to = target.appendingPathComponent(name)
                if fm.fileExists(atPath: to.path) {
                    try fm.removeItem(at: to)
                }
                try fm.copyItem(at: from, to: to)
            }
        }
        try rewritten.text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - PDF

    /// Save the note as a paginated PDF drawn by the same engine as the editor, so code
    /// blocks, tables, math and images match what the user sees, in light colors.
    static func exportPDF(note: Note, noteStore: NoteStore) {
        let current = currentNote(note, noteStore: noteStore)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (savedFilename(of: current) as NSString).deletingPathExtension + ".pdf"
        panel.directoryURL = lastDirectory
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                rememberDirectory(of: url)
                Task { @MainActor in
                    do {
                        let data = try await renderPDF(current)
                        try data.write(to: url, options: .atomic)
                        Log.storage.info("[Export] wrote PDF to \(url.path, privacy: .public)")
                    } catch {
                        fail("PDF", error)
                    }
                }
            }
        }
    }

    private struct RenderError: Error {
        let reason: String
    }

    /// Lay the note out in an offscreen engine view one page-text-column wide, then draw its
    /// layout fragments page by page. Page breaks fall on line boundaries, never mid-line.
    private static func renderPDF(_ note: Note) async throws -> Data {
        let paper = Locale.current.measurementSystem == .us
            ? CGSize(width: 612, height: 792) // US Letter
            : CGSize(width: 595, height: 842) // A4
        let column = CGSize(width: paper.width - 2 * pageMargin, height: paper.height - 2 * pageMargin)
        let aqua = NSAppearance(named: .aqua)

        // Same configuration as the read-only preview, minus the on-screen insets: the
        // page margins take their place.
        let settings = AppSettings.shared
        let fontSize = CGFloat(settings.editorFontSize)
        var config = MarkdownEditorConfiguration.makeEdgeMarkConfig(noteFolder: note.folder, fontSize: fontSize)
        config.textInsets = TextInsets(horizontal: 0, vertical: 0)
        // The math and code bridges pick colors from the key window's appearance, not the
        // view's, so pin them to their light variants for paper.
        config.theme.latexDarkModeText = config.theme.latexLightModeText
        config.services.syntaxHighlighter = HighlighterSwiftBridge(autoSwitchAppearance: false)
        let fontName = settings.editorFontName
            .flatMap { NSFont(name: $0, size: 16)?.familyName } ?? "SF Pro"
        let wrapper = NativeTextViewWrapper(
            text: .constant(MarkdownEditorView.imagesToEmbeds(note.content)),
            configuration: config,
            fontName: fontName,
            fontSize: fontSize,
            documentId: "export-\(note.id.uuidString)",
            isEditable: false,
        )
        let host = NSHostingView(rootView: wrapper.frame(width: column.width, height: column.height))
        host.appearance = aqua
        // Never ordered front; the window only gives the hosting view a place to lay out.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: column),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true,
        )
        window.isReleasedWhenClosed = false
        window.appearance = aqua
        window.contentView = host
        defer { window.close() }

        let layOut = { host.layoutSubtreeIfNeeded() }
        inLightAppearance(aqua, layOut)
        // The engine reconciles table overlays and styling on the next main-queue turns.
        try? await Task.sleep(for: .milliseconds(300))
        inLightAppearance(aqua, layOut)

        guard let textView = findTextView(in: host), let layoutManager = textView.textLayoutManager else {
            throw RenderError(reason: "engine text view not found")
        }
        if abs(textView.frame.width - column.width) > 0.5 {
            textView.setFrameSize(NSSize(width: column.width, height: textView.frame.height))
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        var fragments: [NSTextLayoutFragment] = []
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: NSTextLayoutFragment.EnumerationOptions.ensuresLayout,
        ) { fragment in
            fragments.append(fragment)
            return true
        }

        let pages = pageRanges(for: fragments, pageHeight: column.height)
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: paper)
        let info = [kCGPDFContextTitle as String: note.title] as CFDictionary
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info)
        else {
            throw RenderError(reason: "could not create PDF context")
        }
        let overlays = textView.subviews.compactMap { $0 as? NSScrollView }

        for page in pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            context.saveGState()
            // Flip to the text view's top-left origin and shift the page's slice of the
            // document under the top margin.
            context.translateBy(x: 0, y: paper.height)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: pageMargin, y: pageMargin - page.lowerBound)
            context.clip(to: CGRect(
                x: -pageMargin,
                y: page.lowerBound,
                width: paper.width,
                height: page.upperBound - page.lowerBound,
            ))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let draw = {
                for fragment in fragments {
                    let frame = fragment.layoutFragmentFrame
                    let surface = fragment.renderingSurfaceBounds.offsetBy(dx: frame.minX, dy: frame.minY)
                    let extent = frame.union(surface)
                    guard extent.maxY > page.lowerBound, extent.minY < page.upperBound else { continue }
                    fragment.draw(at: frame.origin, in: context)
                }
                // Tables wider than the column live in horizontally scrolling overlay
                // views; paper cannot scroll, so draw their image shrunk to the column.
                for overlay in overlays {
                    guard overlay.frame.maxY > page.lowerBound, overlay.frame.minY < page.upperBound,
                          let image = (overlay.documentView as? NSImageView)?.image,
                          image.size.width > 0
                    else { continue }
                    let scale = min(1, column.width / image.size.width)
                    context.saveGState()
                    context.clip(to: overlay.frame)
                    image.draw(
                        in: CGRect(
                            x: overlay.frame.minX,
                            y: overlay.frame.minY,
                            width: image.size.width * scale,
                            height: image.size.height * scale,
                        ),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1,
                        respectFlipped: true,
                        hints: nil,
                    )
                    context.restoreGState()
                }
            }
            inLightAppearance(aqua, draw)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Vertical document slices, one per page. A fragment that crosses the page bottom is
    /// split after its last whole line that fits; one that cannot be split moves to the
    /// next page whole. Only a single line taller than a page is cut.
    private static func pageRanges(for fragments: [NSTextLayoutFragment], pageHeight: CGFloat) -> [Range<CGFloat>] {
        var pages: [Range<CGFloat>] = []
        var top: CGFloat = 0
        for fragment in fragments {
            let frame = fragment.layoutFragmentFrame
            while frame.maxY - top > pageHeight {
                let lineBottoms = fragment.textLineFragments.map { frame.minY + $0.typographicBounds.maxY }
                let bottom: CGFloat
                if let fit = lineBottoms.last(where: { $0 > top && $0 - top <= pageHeight }) {
                    bottom = fit
                } else if frame.minY > top {
                    bottom = frame.minY
                } else {
                    bottom = top + pageHeight
                }
                pages.append(top ..< bottom)
                top = bottom
            }
        }
        let end = fragments.last?.layoutFragmentFrame.maxY ?? 0
        pages.append(top ..< max(end, top + 1))
        return pages
    }

    private static func inLightAppearance(_ aqua: NSAppearance?, _ body: () -> Void) {
        if let aqua {
            aqua.performAsCurrentDrawingAppearance { body() }
        } else {
            body()
        }
    }

    private static func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Helpers

    /// The note as the store holds it after flushing pending edits to disk.
    private static func currentNote(_ note: Note, noteStore: NoteStore) -> Note {
        noteStore.saveDirtyNotes()
        return noteStore.notes.first { $0.id == note.id } ?? note
    }

    /// File name on disk ("Title.md"); the asset folder is named after it, not the title.
    private static func savedFilename(of note: Note) -> String {
        note.savedFilename ?? note.filename
    }

    private static var lastDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: lastDirectoryKey),
           FileManager.default.fileExists(atPath: path)
        {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private static func rememberDirectory(of url: URL) {
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: lastDirectoryKey)
    }

    /// No alert: a beep and a log line, so a failed export never blocks the panel.
    private static func fail(_ kind: String, _ error: Error) {
        NSSound.beep()
        Log.storage.error("[Export] \(L10n.shared["export.failed"], privacy: .public) (\(kind, privacy: .public)): \(error)")
    }
}
