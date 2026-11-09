import Foundation

struct OneRepGrant: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scopes: Set<String>

    static func exchange(code: String, verifier: String, redirectURI: String) async throws -> Self {
        try await request([
            "grant_type": "authorization_code", "code": code,
            "code_verifier": verifier, "redirect_uri": redirectURI
        ])
    }

    func renewed() async throws -> Self {
        try await Self.request(["grant_type": "refresh_token", "refresh_token": refreshToken])
    }

    func revoke() async throws {
        _ = try await Self.post("revoke", fields: ["token": refreshToken])
    }

    private static func request(_ fields: [String: String]) async throws -> Self {
        let data = try await post("token", fields: fields)
        return try decodeResponse(data, now: .now)
    }

    static func decodeResponse(_ data: Data, now: Date) throws -> Self {
        struct Response: Decodable {
            let access_token, refresh_token, token_type, scope: String
            let expires_in: Int
        }
        guard let token = try? JSONDecoder().decode(Response.self, from: data),
              token.token_type.lowercased() == "bearer",
              validToken(token.access_token), validToken(token.refresh_token),
              token.expires_in > 0 else { throw OneRepAPIError.invalidResponse }
        let scopes = Set(token.scope.split(separator: " ").map(String.init))
        guard scopes.contains("read") else { throw OneRepAPIError.forbidden }
        return Self(accessToken: token.access_token, refreshToken: token.refresh_token,
                    expiresAt: now.addingTimeInterval(TimeInterval(token.expires_in)), scopes: scopes)
    }

    private static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.allSatisfy { (33...126).contains($0) }
    }

    static func formRequest(_ endpoint: String, fields: [String: String]) -> URLRequest {
        let url = OneRepAPI.origin.appending(path: "oauth").appending(path: endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var fields = fields
        fields["client_id"] = OneRepPublicClient.id
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        return request
    }

    private static func post(_ endpoint: String, fields: [String: String]) async throws -> Data {
        let request = formRequest(endpoint, fields: fields)
        let (data, response) = try await transport.data(for: request, delegate: NoRedirect())
        guard let response = response as? HTTPURLResponse else { throw OneRepAPIError.invalidResponse }
        if (200..<300).contains(response.statusCode) { return data }
        struct Problem: Decodable { let error: String }
        switch (try? JSONDecoder().decode(Problem.self, from: data))?.error {
        case "invalid_grant": throw OneRepAPIError.unauthorized
        case "access_denied", "invalid_scope": throw OneRepAPIError.forbidden
        default: break
        }
        if response.statusCode == 429 { throw OneRepAPIError.rateLimited }
        if response.statusCode >= 500 { throw OneRepAPIError.unavailable }
        throw OneRepAPIError.invalidResponse
    }

    private static let transport: URLSession = {
        let settings = URLSessionConfiguration.ephemeral
        settings.httpShouldSetCookies = false
        settings.httpCookieStorage = nil
        settings.urlCache = nil
        settings.urlCredentialStorage = nil
        settings.timeoutIntervalForRequest = 15
        settings.timeoutIntervalForResource = 30
        return URLSession(configuration: settings)
    }()

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
