import AppKit
import WebKit

// MARK: - MermaidRenderer

/// Renders Mermaid diagrams to vector images with Mermaid's own JavaScript, bundled in the
/// app, in one offscreen `WKWebView`. Diagrams render one at a time, each with a time
/// limit; results are cached in memory and as PDF files on disk, keyed by
/// `MermaidText.cacheKey`, so reopening a note is instant.
///
/// The page is sealed off: a non-persistent data store, a content rule list that blocks
/// every load, a navigation delegate that only lets the initial blank page through, and a
/// Content-Security-Policy with no sources. Note text is never evaluated as JavaScript: the
/// diagram reaches `mermaid.render` only as a call argument, and Mermaid runs with
/// `securityLevel: 'strict'`, which sanitizes labels.
@MainActor
final class MermaidRenderer: NSObject {
    /// What a diagram renders to.
    enum Outcome {
        /// A one-page PDF image at the diagram's natural size, in points.
        case image(NSImage)
        /// Mermaid's error (first line only), or a timeout.
        case failure(String)
    }

    /// Everything besides the source that changes the picture.
    struct Style: Hashable {
        /// Mermaid theme: "dark" or "default".
        var theme: String
        /// CSS `font-family` list for labels.
        var fontFamily: String
    }

    static let shared = MermaidRenderer(
        scriptURL: Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
            ?? Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Resources/Mermaid"),
        cacheDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "EdgeMark", isDirectory: true)
            .appendingPathComponent("mermaid", isDirectory: true),
    )

    /// Posted on the main queue after a diagram finished rendering (or failed).
    static let didRenderNotification = Notification.Name("io.github.ender-wang.EdgeMark.mermaid.didRender")

    /// The failure message of a render that ran out of time.
    static let timeoutMessage = "Timed out"

    let version: String
    /// Per-diagram time limit.
    var timeout: Duration
    private let scriptURL: URL?
    private let cacheDirectory: URL?

    private var images: [String: NSImage] = [:]
    private var failures: [String: String] = [:]
    private var waiters: [String: [CheckedContinuation<Outcome, Never>]] = [:]
    private var queue: [(key: String, code: String, style: Style)] = []
    private var isRunning = false

    private var webView: WKWebView?
    private var ruleList: WKContentRuleList?
    private var allowsInitialLoad = false
    private var loadContinuation: CheckedContinuation<Bool, Never>?
    private var renderCount = 0
    /// JavaScript dialogs the page tried to open (always dismissed). Diagnostic only.
    private(set) var suppressedDialogs = 0

    init(scriptURL: URL?, cacheDirectory: URL?, timeout: Duration = .seconds(10)) {
        self.scriptURL = scriptURL
        self.cacheDirectory = cacheDirectory
        self.timeout = timeout
        let versionURL = scriptURL?.deletingLastPathComponent().appendingPathComponent("VERSION")
        version = versionURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "11"
        super.init()
    }

    // MARK: - Public API

    func key(code: String, style: Style) -> String {
        MermaidText.cacheKey(code: code, theme: style.theme, fontFamily: style.fontFamily, version: version)
    }

    /// The finished result for a diagram, from memory or the disk cache, or nil when it
    /// has not been rendered yet. Never renders.
    func cached(code: String, style: Style) -> Outcome? {
        let key = key(code: code, style: style)
        if let image = images[key] { return .image(image) }
        if let failure = failures[key] { return .failure(failure) }
        if let url = cacheDirectory?.appendingPathComponent(key + ".pdf"),
           let data = try? Data(contentsOf: url),
           let image = Self.pdfImage(data)
        {
            images[key] = image
            return .image(image)
        }
        return nil
    }

    /// Queues a render unless one is cached or pending. `didRenderNotification` follows.
    func request(code: String, style: Style) {
        guard cached(code: code, style: style) == nil else { return }
        Task { _ = await render(code: code, style: style) }
    }

    /// Renders a diagram (or returns the cached result), waiting in line behind others.
    func render(code: String, style: Style) async -> Outcome {
        if let outcome = cached(code: code, style: style) { return outcome }
        let key = key(code: code, style: style)
        return await withCheckedContinuation { continuation in
            let isNew = waiters[key] == nil
            waiters[key, default: []].append(continuation)
            if isNew {
                queue.append((key, code, style))
                pump()
            }
        }
    }

    /// Renders `codes` in order, returning when all are done or `limit` has passed,
    /// whichever comes first. Renders still running then finish in the background.
    func prepare(_ codes: [String], style: Style, within limit: Duration) async {
        guard !codes.isEmpty else { return }
        let gate = OnceGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                for code in codes {
                    _ = await self.render(code: code, style: style)
                }
                if gate.claim() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(for: limit)
                if gate.claim() { continuation.resume() }
            }
        }
    }

    // MARK: - Queue

    private func pump() {
        guard !isRunning, !queue.isEmpty else { return }
        isRunning = true
        let job = queue.removeFirst()
        Task {
            let outcome = await renderWithTimeout(code: job.code, style: job.style)
            switch outcome {
            case let .image(image):
                images[job.key] = image
                if let data = image.representations.compactMap({ ($0 as? NSPDFImageRep)?.pdfRepresentation }).first {
                    saveToDisk(data, key: job.key)
                }
            case let .failure(message):
                failures[job.key] = message
            }
            for waiter in waiters.removeValue(forKey: job.key) ?? [] {
                waiter.resume(returning: outcome)
            }
            NotificationCenter.default.post(name: Self.didRenderNotification, object: nil)
            isRunning = false
            pump()
        }
    }

    /// Races the render against `timeout`. On a timeout the web view is thrown away, so
    /// a diagram that hangs Mermaid cannot stall the ones queued behind it.
    private func renderWithTimeout(code: String, style: Style) async -> Outcome {
        let gate = OnceGate()
        return await withCheckedContinuation { continuation in
            Task {
                let outcome = await self.renderInWebView(code: code, style: style)
                if gate.claim() { continuation.resume(returning: outcome) }
            }
            Task {
                try? await Task.sleep(for: self.timeout)
                if gate.claim() {
                    self.discardWebView()
                    continuation.resume(returning: .failure(Self.timeoutMessage))
                }
            }
        }
    }

    private final class OnceGate {
        private var done = false
        func claim() -> Bool {
            if done { return false }
            done = true
            return true
        }
    }

    // MARK: - Web view

    private static let page = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:">
    <style>html,body{margin:0;padding:0;background:transparent}#out{width:800px}</style>
    </head><body><div id="out"></div></body></html>
    """

    /// Blocks every load; the initial `about:blank` page is the navigation delegate's call.
    private static let rules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]
    """

    private func readyWebView() async -> WKWebView? {
        if let webView { return webView }
        guard let scriptURL, let script = try? String(contentsOf: scriptURL, encoding: .utf8) else { return nil }
        if ruleList == nil {
            ruleList = try? await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: "edgemark.mermaid.offline", encodedContentRuleList: Self.rules)
        }
        // Fail closed: no rule list, no page.
        guard let ruleList else { return nil }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(ruleList)
        // The app's own script, run once the blank page has loaded: defines `mermaid`.
        configuration.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true),
        )
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1200), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.setValue(false, forKey: "drawsBackground")

        let loaded = await withCheckedContinuation { continuation in
            loadContinuation = continuation
            allowsInitialLoad = true
            view.loadHTMLString(Self.page, baseURL: nil)
        }
        allowsInitialLoad = false
        guard loaded else { return nil }
        webView = view
        return view
    }

    private func discardWebView() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
    }

    /// Mermaid render: lay out at natural size, report that size, then take a PDF of it.
    private static let renderScript = """
    const out = document.getElementById('out');
    out.innerHTML = '';
    document.querySelectorAll('body > :not(#out)').forEach((n) => n.remove());
    try {
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        theme: theme,
        fontFamily: fontFamily,
        themeVariables: { fontFamily: fontFamily },
        flowchart: { useMaxWidth: false },
        sequence: { useMaxWidth: false },
        class: { useMaxWidth: false },
        state: { useMaxWidth: false },
        er: { useMaxWidth: false },
        gantt: { useMaxWidth: false },
        pie: { useMaxWidth: false },
        mindmap: { useMaxWidth: false },
      });
      const { svg } = await mermaid.render(id, code);
      out.innerHTML = svg;
      const element = out.querySelector('svg');
      if (!element) { return { error: 'No diagram' }; }
      const box = element.viewBox && element.viewBox.baseVal;
      let width = box && box.width ? box.width : element.getBoundingClientRect().width;
      let height = box && box.height ? box.height : element.getBoundingClientRect().height;
      element.setAttribute('width', width);
      element.setAttribute('height', height);
      element.style.maxWidth = 'none';
      element.style.display = 'block';
      return { width: width, height: height };
    } catch (error) {
      document.querySelectorAll('body > :not(#out)').forEach((n) => n.remove());
      const message = String((error && error.message) || error || 'Error');
      return { error: message };
    }
    """

    private func renderInWebView(code: String, style: Style) async -> Outcome {
        guard let view = await readyWebView() else { return .failure("Renderer unavailable") }
        renderCount += 1
        let result: Any?
        do {
            result = try await view.callAsyncJavaScript(
                Self.renderScript,
                arguments: [
                    "code": code,
                    "theme": style.theme,
                    "fontFamily": style.fontFamily,
                    "id": "mermaid-\(renderCount)",
                ],
                contentWorld: .page,
            )
        } catch {
            return .failure(Self.firstLine(error.localizedDescription))
        }
        guard let values = result as? [String: Any] else { return .failure("No diagram") }
        if let message = values["error"] as? String {
            return .failure(Self.firstLine(message))
        }
        guard let width = (values["width"] as? NSNumber)?.doubleValue,
              let height = (values["height"] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return .failure("No diagram") }

        let size = CGSize(width: ceil(width), height: ceil(height))
        view.frame = CGRect(origin: .zero, size: CGSize(width: max(size.width, 1), height: max(size.height, 1)))
        let pdf = WKPDFConfiguration()
        pdf.rect = CGRect(origin: .zero, size: size)
        guard let data = try? await view.pdf(configuration: pdf), let image = Self.pdfImage(data) else {
            return .failure("Could not draw the diagram")
        }
        return .image(image)
    }

    // MARK: - Helpers

    private static func pdfImage(_ data: Data) -> NSImage? {
        guard let rep = NSPDFImageRep(data: data), rep.bounds.width > 0, rep.bounds.height > 0 else { return nil }
        let image = NSImage(size: rep.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func firstLine(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return line.trimmingCharacters(in: .whitespaces)
    }

    private func saveToDisk(_ data: Data, key: String) {
        guard let cacheDirectory else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheDirectory.appendingPathComponent(key + ".pdf"), options: .atomic)
    }
}

// MARK: - Sealing the page

extension MermaidRenderer: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void,
    ) {
        let isInitialPage = allowsInitialLoad && action.targetFrame?.isMainFrame == true
            && (action.request.url?.absoluteString ?? "about:blank") == "about:blank"
        decisionHandler(isInitialPage ? .allow : .cancel)
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        loadContinuation?.resume(returning: true)
        loadContinuation = nil
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        loadContinuation?.resume(returning: false)
        loadContinuation = nil
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
        loadContinuation?.resume(returning: false)
        loadContinuation = nil
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        discardWebView()
    }

    func webView(
        _: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for _: WKNavigationAction,
        windowFeatures _: WKWindowFeatures,
    ) -> WKWebView? {
        nil
    }

    func webView(
        _: WKWebView,
        runJavaScriptAlertPanelWithMessage _: String,
        initiatedByFrame _: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void,
    ) {
        suppressedDialogs += 1
        completionHandler()
    }
}
