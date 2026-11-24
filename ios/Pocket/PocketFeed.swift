import Foundation

final class PocketFeed: NSObject, URLSessionTaskDelegate {
    private struct Config: Decodable {
        let feedUrl: URL
    }

    private static let maxBytes = 128 * 1024
    private let url: URL? = {
        guard let file = Bundle.main.url(forResource: "mobile", withExtension: "json"),
              let data = try? Data(contentsOf: file),
              let config = try? JSONDecoder().decode(Config.self, from: data),
              config.feedUrl.scheme == "https", let host = config.feedUrl.host, !host.isEmpty,
              config.feedUrl.user == nil, config.feedUrl.password == nil,
              config.feedUrl.fragment == nil else { return nil }
        return config.feedUrl
    }()

    func fetch() async -> String? {
        guard let url else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: self)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.expectedContentLength <= Self.maxBytes else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maxBytes else { return nil }
                data.append(byte)
            }
            return Self.validate(data)
        } catch {
            return nil
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private static func validate(_ data: Data) -> String? {
        guard String(data: data, encoding: .utf8) != nil,
              let value = try? JSONSerialization.jsonObject(with: data),
              let feed = value as? [String: Any], feed.count == 2, feed["title"] is String,
              let items = feed["items"] as? [[String: Any]], items.count <= 100,
              items.allSatisfy({ $0.count == 2 && $0["title"] is String && $0["body"] is String }),
              let payload = try? JSONSerialization.data(withJSONObject: feed) else { return nil }
        return String(data: payload, encoding: .utf8)
    }
}
