import SwiftUI
import WebKit

// Блоки ```mermaid → схема (SVG) через pele (Resources/mermaid/pele.js, лежит в бандле, из сети ничего не грузится).
// При ошибке рисования — исходный текст кода, как у обычного блока.

/// WKWebView, который не перехватывает прокрутку: колесо уходит ленте чата
final class PassThroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
}

struct MermaidView: View {
    let source: String
    let size: CGFloat
    let selectable: Bool
    @State private var height: CGFloat = 80
    @State private var failed = false

    var body: some View {
        Group {
        if failed || MermaidAssets.indexURL == nil {
            fallback
        } else {
            MermaidWeb(source: source, height: $height, failed: $failed)
                .frame(maxWidth: .infinity)
                .frame(height: height)
        }
        }
        .onChange(of: source) { _, _ in failed = false }
    }

    private var fallback: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(source)
                .font(.system(size: size - 1.5, design: .monospaced))
                .lineSpacing(2)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .modifier(SelectableIf(on: selectable))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

enum MermaidAssets {
    static let indexURL: URL? = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "mermaid")
}

struct MermaidWeb: NSViewRepresentable {
    let source: String
    @Binding var height: CGFloat
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(WeakHandler(context.coordinator), name: "pia")
        let w = PassThroughWebView(frame: .zero, configuration: cfg)
        w.setValue(false, forKey: "drawsBackground")
        w.navigationDelegate = context.coordinator
        context.coordinator.web = w
        if let url = MermaidAssets.indexURL {
            w.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.draw(source)
    }

    final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: Coordinator?
        init(_ t: Coordinator) { target = t }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.receive(m.body) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MermaidWeb
        weak var web: WKWebView?
        var ready = false
        var drawn: String?
        init(_ p: MermaidWeb) { parent = p }

        func receive(_ body: Any) {
            guard let d = body as? [String: Any] else { return }
            if d["ready"] != nil { ready = true; draw(parent.source); return }
            if let e = d["error"] as? String {
                NSLog("pia mermaid: ошибка рисования: %@", e)
                DispatchQueue.main.async { self.parent.failed = true }
            } else if let h = d["h"] as? Double, h > 0 {
                DispatchQueue.main.async { if abs(self.parent.height - h) > 0.5 { self.parent.height = CGFloat(h) } }
            }
        }

        func draw(_ src: String) {
            guard ready, drawn != src, let web else { return }
            drawn = src
            let lit = (try? JSONSerialization.data(withJSONObject: [src], options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            web.evaluateJavaScript("draw(\(lit)[0])", completionHandler: nil)
        }

        // ссылки внутри схемы не открываем
        func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(a.navigationType == .linkActivated ? .cancel : .allow)
        }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { DispatchQueue.main.async { self.parent.failed = true } }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { DispatchQueue.main.async { self.parent.failed = true } }
    }
}
