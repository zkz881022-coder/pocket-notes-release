import WebKit
import UniformTypeIdentifiers

final class PocketAssets: NSObject, WKURLSchemeHandler {
    private static let policy = [
        "default-src 'self' pocket:",
        "script-src 'self' pocket: 'unsafe-inline'",
        "style-src 'self' pocket: 'unsafe-inline'",
        "img-src 'self' pocket: data:",
        "font-src 'self' pocket: data:",
        "connect-src 'self' pocket:",
        "frame-src 'none'",
        "object-src 'none'",
        "worker-src 'none'",
        "form-action 'none'",
        "base-uri 'self' pocket:"
    ].joined(separator: "; ")

    static func path(for url: URL) -> String? {
        guard url.scheme == "pocket", url.host == "app", url.user == nil,
              url.password == nil, url.port == nil else { return nil }
        let path = url.path
        if path.isEmpty || path == "/" {
            return "index.html"
        }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: {
            $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\\") || $0.contains("\0")
        }) else { return nil }
        return parts.joined(separator: "/")
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, task.request.httpMethod == "GET",
              let path = Self.path(for: url),
              let root = Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true),
              let data = try? Data(contentsOf: root.appendingPathComponent(path), options: .mappedIfSafe)
        else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let ext = (path as NSString).pathExtension.lowercased()
        let contentType = Self.mimeType(ext)
        let headers = [
            "Content-Type": contentType,
            "Content-Length": String(data.count),
            "Content-Security-Policy": Self.policy,
            "Access-Control-Allow-Origin": "*",
            "X-Content-Type-Options": "nosniff"
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: headers) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Resource tasks finish synchronously inside start.
    }

    private static func mimeType(_ ext: String) -> String {
        switch ext {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "application/javascript"
        case "json": return "application/json"
        case "wasm": return "application/wasm"
        case "svg": return "image/svg+xml"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
