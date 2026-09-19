import AppKit
import SwiftUI
import WebKit

enum NethrivaWindow {
    static let help = "nethriva-help"
}

struct NethrivaHelpView: View {
    var body: some View {
        NethrivaHelpWebView()
            .frame(minWidth: 760, minHeight: 560)
            .accessibilityLabel("Nethriva Help")
    }
}

private struct NethrivaHelpWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.navigationDelegate = context.coordinator
        loadHelp(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func loadHelp(in webView: WKWebView) {
        guard let helpURL = Bundle.main.url(forResource: "NethrivaHelp", withExtension: "html") else {
            webView.loadHTMLString(Self.missingHelpHTML, baseURL: nil)
            return
        }

        webView.loadFileURL(
            helpURL,
            allowingReadAccessTo: helpURL.deletingLastPathComponent()
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard
                navigationAction.navigationType == .linkActivated,
                let url = navigationAction.request.url,
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else {
                decisionHandler(.allow)
                return
            }

            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    private static let missingHelpHTML = """
    <!doctype html>
    <html lang="en">
    <meta charset="utf-8">
    <style>
      body { font: 15px -apple-system, BlinkMacSystemFont, sans-serif; padding: 40px; color: #202633; }
      h1 { color: #15233f; }
      code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    </style>
    <h1>Nethriva Help is unavailable</h1>
    <p>The bundled help file could not be found. Clean the Xcode build folder and build Nethriva again.</p>
    <p>Expected resource: <code>NethrivaHelp.html</code></p>
    </html>
    """
}

struct NethrivaHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Nethriva Help") {
                openWindow(id: NethrivaWindow.help)
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}
