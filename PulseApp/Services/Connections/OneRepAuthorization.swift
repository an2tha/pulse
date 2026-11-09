import CryptoKit
import Foundation
import Security

struct OneRepAuthorization {
    static let callbackScheme = "app.pulseplanner.pulse"
    static let redirectURI = "app.pulseplanner.pulse://oauth/onerep"

    let verifier: String
    let state: String

    init() throws {
        verifier = try Self.nonce()
        state = try Self.nonce()
    }

    func authorizationURL(clientID: String) -> URL {
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        return OneRepAPI.origin.appending(path: "oauth/authorize").appending(queryItems: [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "read write"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256")
        ])
    }

    func code(from url: URL) throws -> String {
        guard var callback = URLComponents(url: url, resolvingAgainstBaseURL: false),
              callback.fragment == nil else { throw OneRepSignInError.invalidCallback }
        let parameters = callback.queryItems ?? []
        callback.query = nil
        let states = parameters.filter { $0.name == "state" }
        guard callback.string == Self.redirectURI, states.count == 1, states.first?.value == state else {
            throw OneRepSignInError.invalidCallback
        }
        let errors = parameters.filter { $0.name == "error" }
        let codes = parameters.filter { $0.name == "code" }
        if !errors.isEmpty {
            if errors.count == 1, errors.first?.value == "access_denied", codes.isEmpty { throw CancellationError() }
            throw OneRepSignInError.invalidCallback
        }
        guard codes.count == 1, let code = codes.first?.value, !code.isEmpty else {
            throw OneRepSignInError.invalidCallback
        }
        return code
    }

    private static func nonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw OneRepSignInError.couldNotStart }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum OneRepSignInError: LocalizedError {
    case couldNotStart, invalidCallback, alreadySigningIn
    var errorDescription: String? {
        switch self {
        case .couldNotStart: "Open Pulse and tap Connect to start OneRep sign-in again."
        case .invalidCallback: "Pulse couldn’t verify this sign-in. Tap Connect to try again."
        case .alreadySigningIn: "Finish the OneRep sign-in already open in Pulse."
        }
    }
}
