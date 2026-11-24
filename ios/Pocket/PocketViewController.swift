import UIKit
import WebKit

final class PocketViewController: UIViewController, WKNavigationDelegate {
    private let assets = PocketAssets()
    private let feed = PocketFeed()
    private let latestKey = "latestPocketFeed"
    private var web: WKWebView!
    private var latest: String?
    private var timer: Timer?
    private var loadingFeed = false
    private var pageReady = false

    override func loadView() {
        let settings = WKWebViewConfiguration()
        settings.setURLSchemeHandler(assets, forURLScheme: "pocket")
        settings.preferences.javaScriptCanOpenWindowsAutomatically = false
        web = WKWebView(frame: .zero, configuration: settings)
        web.navigationDelegate = self

        let container = UIView()
        container.backgroundColor = UIColor(red: 244 / 255, green: 240 / 255, blue: 230 / 255, alpha: 1)
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        view = container
        latest = UserDefaults.standard.string(forKey: latestKey)
        web.load(URLRequest(url: URL(string: "pocket://app/index.html")!))
    }

    func startRefreshing() {
        loadViewIfNeeded()
        stopRefreshing()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopRefreshing() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard !loadingFeed else { return }
        loadingFeed = true
        Task {
            let response = await feed.fetch()
            loadingFeed = false
            guard let response, response != latest else { return }
            latest = response
            UserDefaults.standard.set(response, forKey: latestKey)
            showFeed()
        }
    }

    private func showFeed() {
        guard pageReady, let latest else { return }
        web.callAsyncJavaScript(
            "window.dispatchEvent(new CustomEvent('pocket-feed', { detail: JSON.parse(payload) }));",
            arguments: ["payload": latest],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = action.targetFrame?.isMainFrame == true
            && action.request.httpMethod == "GET"
            && action.request.url.flatMap(PocketAssets.path(for:)) != nil
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pageReady = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = webView.url.flatMap(PocketAssets.path(for:)) != nil
        showFeed()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageReady = false
        webView.reload()
    }
}
