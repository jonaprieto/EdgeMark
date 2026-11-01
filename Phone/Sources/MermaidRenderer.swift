import UIKit
import SwiftUI
import WebKit

/// Renders Mermaid diagrams to vector images with the bundled Mermaid script in one offscreen web view.
///
/// The page loads nothing from the network: a content-security policy with no remote sources and a
/// navigation delegate that only lets the initial page through. Diagram text is never evaluated as
/// JavaScript; it reaches `mermaid.render` as a call argument, with `securityLevel: 'strict'`.
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidRenderer()

    enum Outcome {
        case image(UIImage)
        case failure(String)
    }

    private var webView: WKWebView?
    private var loading: [CheckedContinuation<Bool, Never>] = []
    private var loaded = false
    private var cache: [String: UIImage] = [:]
    private var counter = 0
    /// Renders run one at a time: they share one page.
    private var tail: Task<Void, Never>?

    // scripts/phone.sh copies the Mac app's bundled script next to the binary.
    private static let script = Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    private func ready() async -> WKWebView? {
        if let webView, loaded { return webView }
        guard let script = Self.script else { return nil }
        if webView == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1200), configuration: config)
            view.navigationDelegate = self
            view.isOpaque = false
            view.backgroundColor = .clear
            webView = view
            let page = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:">
            <style>html,body{margin:0;background:transparent}#out{display:inline-block}</style></head>
            <body><div id="out"></div><script>\(script)</script></body></html>
            """
            view.loadHTMLString(page, baseURL: nil)
        }
        let ok = await withCheckedContinuation { loading.append($0) }
        return ok ? webView : nil
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        loaded = true
        loading.forEach { $0.resume(returning: true) }
        loading = []
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        loading.forEach { $0.resume(returning: false) }
        loading = []
    }

    func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Only the initial inline page; a diagram cannot navigate anywhere.
        action.request.url?.absoluteString == "about:blank" && !loaded ? .allow : .cancel
    }

    private static let renderScript = """
    const out = document.getElementById('out');
    out.innerHTML = '';
    document.querySelectorAll('body > :not(#out):not(script)').forEach((n) => n.remove());
    try {
      const flat = { useMaxWidth: false };
      mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: theme, fontFamily: fontFamily,
        themeVariables: { fontFamily: fontFamily, fontSize: fontSize + 'px' },
        flowchart: flat, sequence: flat, class: flat, state: flat, er: flat, gantt: flat, pie: flat, mindmap: flat });
      const { svg } = await mermaid.render(id, code);
      out.innerHTML = svg;
      const element = out.querySelector('svg');
      if (!element) { return { error: 'No diagram' }; }
      const box = element.viewBox && element.viewBox.baseVal;
      const width = box && box.width ? box.width : element.getBoundingClientRect().width;
      const height = box && box.height ? box.height : element.getBoundingClientRect().height;
      element.setAttribute('width', width);
      element.setAttribute('height', height);
      element.style.maxWidth = 'none';
      element.style.display = 'block';
      return { width: width, height: height };
    } catch (error) {
      document.querySelectorAll('body > :not(#out):not(script)').forEach((n) => n.remove());
      return { error: String((error && error.message) || error || 'Error').split('\\n')[0] };
    }
    """

    func render(_ code: String, dark: Bool, fontFamily: String, fontSize: Double) async -> Outcome {
        let key = "\(dark)|\(fontFamily)|\(fontSize)|\(code)"
        if let hit = cache[key] { return .image(hit) }
        let previous = tail
        let task = Task { () -> Outcome in
            await previous?.value
            return await self.renderNow(code, dark: dark, fontFamily: fontFamily, fontSize: fontSize)
        }
        tail = Task { _ = await task.value }
        let outcome = await task.value
        if case let .image(image) = outcome {
            if cache.count > 150 { cache.removeAll() }
            cache[key] = image
        }
        return outcome
    }

    private func renderNow(_ code: String, dark: Bool, fontFamily: String, fontSize: Double) async -> Outcome {
        guard let view = await ready() else { return .failure("Mermaid is unavailable") }
        counter += 1
        do {
            let result = try await view.callAsyncJavaScript(Self.renderScript, arguments: [
                "code": code, "theme": dark ? "dark" : "default", "fontFamily": fontFamily, "fontSize": fontSize, "id": "m\(counter)",
            ], contentWorld: .page)
            guard let info = result as? [String: Any] else { return .failure("No result") }
            if let error = info["error"] as? String { return .failure(error) }
            guard let w = info["width"] as? Double, let h = info["height"] as? Double, w > 0, h > 0 else { return .failure("Empty diagram") }
            let pdf = WKPDFConfiguration()
            pdf.rect = CGRect(x: 0, y: 0, width: w, height: h)
            let data = try await view.pdf(configuration: pdf)
            guard let image = diagramImage(pdf: data, size: CGSize(width: w, height: h)) else { return .failure("Could not draw the diagram") }
            return .image(image)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

/// The first page of a diagram's PDF as a sharp image.
private func diagramImage(pdf data: Data, size: CGSize) -> UIImage? {
    guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
          let page = document.page(at: 1) else { return nil }
    let scale = min(2, 2048 / max(size.width, size.height))
    let output = CGSize(width: size.width * scale, height: size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: output, format: format).image { context in
        context.cgContext.translateBy(x: 0, y: output.height)
        context.cgContext.scaleBy(x: scale, y: -scale)
        context.cgContext.drawPDFPage(page)
    }
}
