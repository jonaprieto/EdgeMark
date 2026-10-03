import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// "Export as Markdown" and "Export as PDF" for a single note. Writes a copy chosen through
/// a save panel and never touches the note itself or its asset folder. "Export as Gist"
/// is the exception: it moves the note into the gist's clone (see `exportAsGist`).
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
        let exportedStem = url.deletingPathExtension().lastPathComponent
        // Images live under the safe asset stem, or the plain file stem for folders created
        // before stems were made safe; rewrite links to either.
        let stems = FileStorage.assetStems(for: note)
        var text = note.content
        var imageNames: [String] = []
        for stem in stems {
            let rewritten = ExportLinks.rewriteImageLinks(in: text, stem: stem, exportedStem: exportedStem)
            text = rewritten.text
            imageNames += rewritten.imageNames.filter { !imageNames.contains($0) }
        }

        // Copy the images first so a failure leaves no .md pointing at missing files.
        if !imageNames.isEmpty {
            let sources = stems.map { FileStorage.assetDirURL(stem: $0, folder: note.folder) }
            let target = url.deletingLastPathComponent()
                .appendingPathComponent("\(exportedStem)-images", isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for name in imageNames {
                let candidates = sources.map { $0.appendingPathComponent(name) }
                guard let from = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
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
        try text.write(to: url, atomically: true, encoding: .utf8)
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
        // Diagrams render first (light, at most 10 s in all); any still pending export as source.
        await MermaidRenderer.shared.prepare(for: note.content)
        // The math and code bridges pick colors from the key window's appearance, not the
        // view's, so pin them to their light variants for paper.
        var config = MarkdownEditorConfiguration.makeEdgeMarkConfig(
            noteFolder: note.folder,
            fontSize: fontSize,
            mermaidColumn: MermaidColumn(width: column.width - 10),
            pinsLightAppearance: true,
        )
        config.textInsets = TextInsets(horizontal: 0, vertical: 0)
        config.theme.latexDarkModeText = config.theme.latexLightModeText
        let fontName = settings.editorFontName
            .flatMap { NSFont(name: $0, size: 16)?.familyName } ?? "SF Pro"
        let wrapper = NativeTextViewWrapper(
            text: .constant(MarkdownEditorView.exportDisplayText(note.content)),
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

    // MARK: - Gist

    /// Which gist items the note's menus show; see `GistExportOffer`.
    static func gistOffer(for note: Note) -> GistExportOffer {
        GistExportOffer.decide(
            folder: note.folder,
            hasImages: FileStorage.hasAssetDirectory(for: note),
            syncActive: GitSync.shared.isActive,
        )
    }

    /// Put the web link of the gist holding `note` on the clipboard. Does nothing when
    /// the note is not inside a gist clone.
    static func copyGistLink(note: Note) {
        let url = FileStorage.urlForNote(note)
        Task { @MainActor in
            guard let info = await GitSync.shared.gistInfo(for: url) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(info.webURL.absoluteString, forType: .string)
        }
    }

    /// Open the gist holding `note` in the browser.
    static func openGist(note: Note) {
        let url = FileStorage.urlForNote(note)
        Task { @MainActor in
            guard let info = await GitSync.shared.gistInfo(for: url) else { return }
            NSWorkspace.shared.open(info.webURL)
        }
    }

    /// Publish the note as a gist and move it into the gist's clone under `Gists/`, so the
    /// normal sync keeps the two in step both ways. Asks first (see `confirmPublish`), puts
    /// the gist link on the clipboard and shows a toast either way. Used by the note
    /// context menu and the editor's export menu.
    static func exportAsGist(note: Note, noteStore: NoteStore, isPublic: Bool) {
        let sync = GitSync.shared
        let l10n = L10n.shared
        let url = FileStorage.urlForNote(note)
        Task { @MainActor in
            noteStore.saveDirtyNotes()
            guard await confirmPublish(note: note, file: url, isPublic: isPublic, l10n: l10n) else { return }
            switch await sync.publishAsGist(file: url, description: note.title, isPublic: isPublic) {
            case let .success(result):
                let folder = "Gists/\(result.gistDir.lastPathComponent)"
                noteStore.moveNote(note, to: folder)
                // publishAsGist cleared the file in the clone so the move could land
                // there. If the move failed, restore the uploaded copy and do not
                // push an empty gist.
                let filename = url.lastPathComponent
                let moved = result.gistDir.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: moved.path) else {
                    _ = await GitRepo(url: result.gistDir).git("checkout", "--", filename)
                    sync.lastSetupError = l10n["sync.publishMoveFailed"]
                    FeedbackToast.shared.show(l10n.t("sync.publishFailed", l10n["sync.publishMoveFailed"]), isError: true)
                    SyncLog.log.error("[Gist] note move into \(folder, privacy: .public) failed")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.webURL.absoluteString, forType: .string)
                FeedbackToast.shared.show(l10n["sync.publishDone"])
                await sync.commitAndPush(GitRepo(url: result.gistDir))
            case let .failure(error):
                sync.lastSetupError = error.message
                FeedbackToast.shared.show(l10n.t("sync.publishFailed", shortMessage(error.message)), isError: true)
                SyncLog.log.error("[Gist] publish failed: \(error.message, privacy: .public)")
            }
        }
    }

    /// First line of `message`, cut to 120 characters, for the publish toast.
    private static func shortMessage(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return line.count > 120 ? String(line.prefix(117)) + "..." : line
    }

    /// Asks before publishing. A private gist asks only when the guard flags the note; a
    /// public gist always asks, with stricter thresholds. Reasons never quote the note.
    private static func confirmPublish(note: Note, file: URL, isPublic: Bool, l10n: L10n) async -> Bool {
        let verdicts = await GitSync.shared.checkBeforePublish(file: file, strict: isPublic)
        var reasons: [String] = []
        for reason in verdicts.flatMap(\.reasons) where !reasons.contains(reason) {
            reasons.append(reason)
        }
        let reasonLine = l10n.t("sync.secretsReasons", reasons.joined(separator: ", "))
        let alert = NSAlert()
        alert.alertStyle = .warning
        if isPublic {
            alert.messageText = l10n.t("sync.publishPublicTitle", note.title)
            alert.informativeText = l10n["sync.publishPublicInfo"] + (reasons.isEmpty ? "" : "\n\n" + reasonLine)
            alert.addButton(withTitle: l10n["common.cancel"])
            alert.addButton(withTitle: l10n[reasons.isEmpty ? "sync.publishPublic" : "sync.publishPublicAnyway"])
        } else {
            guard !reasons.isEmpty else { return true }
            alert.messageText = l10n["sync.secretsTitle"]
            alert.informativeText = reasonLine
            alert.addButton(withTitle: l10n["common.cancel"])
            alert.addButton(withTitle: l10n["sync.publishPrivateAnyway"])
        }
        return alert.runModal() == .alertSecondButtonReturn
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
