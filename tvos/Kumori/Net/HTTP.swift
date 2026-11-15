import Foundation

struct APIError: LocalizedError {
    let message: String
    var code = 0
    var errorDescription: String? { message }
}

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpCookieStorage = nil
        return URLSession(configuration: c)
    }()

    static func request(_ url: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) throws -> URLRequest {
        guard let u = URL(string: url) else { throw APIError(message: "Bad address: \(url)") }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.httpBody = body
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    /// Sends a request and returns the status code with the decoded body.
    static func send(_ r: URLRequest) async throws -> (Int, J) {
        let (data, response) = try await session.data(for: r)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, J(data: data))
    }

    /// Like `send`, but anything other than a 2xx answer is an error.
    static func json(_ r: URLRequest) async throws -> J {
        let (code, j) = try await send(r)
        if code == 401 || code == 403 { throw APIError(message: "Your sign-in has expired.", code: code) }
        guard (200..<300).contains(code) else { throw APIError(message: "The server answered \(code).", code: code) }
        guard j.exists else { throw APIError(message: "The server sent an unreadable answer.") }
        return j
    }

    static func form(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}
