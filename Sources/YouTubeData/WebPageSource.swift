#if canImport(WebKit)
import Foundation
import Support
import WebKit

/// Loads public YouTube pages in an offscreen WKWebView (section 7.2). Each load uses a
/// fresh, non-persistent web view, so nothing is remembered between pages and no
/// YouTube sign-in is ever used. Wrap it in `PacedPageSource` to keep the pace polite.
public struct WebPageSource: PageSource {
    public init() {}

    public func load(_ url: URL) async throws -> PageResult {
        try await WebPageLoad.run(url)
    }
}

@MainActor
final class WebPageLoad: NSObject, WKNavigationDelegate {
    /// Reads the embedded data objects after scripts have run, and rebuilds a page
    /// the shared `PageData` parser understands.
    static let script = """
    (function () {
      function grab(v) { try { return v ? JSON.stringify(v) : null; } catch (e) { return null; } }
      return JSON.stringify({ d: grab(window.ytInitialData), p: grab(window.ytInitialPlayerResponse) });
    })()
    """

    private let webView: WKWebView
    private var continuation: CheckedContinuation<PageResult, Error>?
    private var status = 200

    private init(webView: WKWebView) {
        self.webView = webView
    }

    static func run(_ url: URL, timeout: TimeInterval = 30) async throws -> PageResult {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        let load = WebPageLoad(webView: webView)
        webView.navigationDelegate = load
        return try await withCheckedThrowingContinuation { continuation in
            load.continuation = continuation
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            webView.load(request)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout + 5) {
                MainActor.assumeIsolated {
                    load.finish(.failure(YTAError(.network, "The YouTube page took too long to load.")))
                }
            }
        }
    }

    private func finish(_ result: Result<PageResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse {
            status = response.statusCode
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if status == 404 {
            finish(.success(PageResult(status: 404, html: "")))
            return
        }
        webView.evaluateJavaScript(Self.script) { [weak self] value, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard error == nil, let text = value as? String,
                      let parts = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                    self.finish(.failure(YTAError(.fileFormat, "The YouTube page could not be read.")))
                    return
                }
                var html = ""
                if let data = parts["d"] as? String { html += "<script>var ytInitialData = \(data);</script>\n" }
                if let player = parts["p"] as? String { html += "<script>var ytInitialPlayerResponse = \(player);</script>\n" }
                self.finish(.success(PageResult(status: self.status, html: html)))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(YTAError(.network, "YouTube could not be reached.")))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(YTAError(.network, "YouTube could not be reached.")))
    }
}
#endif
