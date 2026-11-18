import SwiftUI
import WebKit

/// Reloads the user interface by loading a WebKit payload that puts the
/// renderer under memory pressure, which makes SpringBoard restart.
///
/// This is the same technique Placard uses (NeoSpring, credited there to
/// rooootdev, skadz108 and neonmodder123). A sandboxed app cannot call launchctl or signal
/// SpringBoard directly, so this is the one approach that works without a
/// jailbreak-style entitlement.
struct NeoSpringView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.loadHTMLString(Self.document, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: ()) {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private static let document = #"""
    <!DOCTYPE html>
    <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body,iframe{margin:0;width:100%;height:100%;border:0;background:#000;overflow:hidden}</style>
      </head>
      <body>
        <iframe id="frame" srcdoc="" sandbox="allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups allow-presentation allow-scripts"></iframe>
        <script>
          const frame = document.getElementById('frame');
          const payload = `
            <html><body style="margin:0;background:#000;overflow:hidden"><script>
              const container = document.createElement('div');
              container.style.cssText = 'perspective:1px;perspective-origin:9999999% 9999999%;';
              document.body.appendChild(container);
              for (let i = 0; i < 500; i++) {
                const layer = document.createElement('div');
                layer.style.cssText = 'position:absolute;width:100vw;height:100vh;backdrop-filter:blur(100px);-webkit-backdrop-filter:blur(100px);transform:translate3d(100000px,100000px,' + i + 'px) rotateY(90deg);';
                container.appendChild(layer);
              }
              setInterval(() => {
                navigator.share({title:'R',text:'R'.repeat(100000)}).catch(() => {});
                const bytes = new Uint8Array(1024 * 1024 * 10);
                crypto.getRandomValues(bytes);
              }, 0);
            <\/script></body></html>`;
          frame.srcdoc = payload;
        </script>
      </body>
    </html>
    """#
}

/// Full-screen host for the payload, shown while the interface reloads.
struct NeoSpringOverlay: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var canClose = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NeoSpringView().ignoresSafeArea()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            if canClose {
                VStack {
                    HStack {
                        Spacer()
                        Button(L("COMMON_CLOSE")) { dismiss() }
                            .buttonStyle(.borderedProminent)
                            .tint(.white.opacity(0.25))
                            .foregroundStyle(.white)
                            .padding(20)
                    }
                    Spacer()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { dismiss() }
        }
        .task {
            do {
                try await Task.sleep(for: .seconds(5))
                canClose = true
            } catch {}
        }
    }
}
