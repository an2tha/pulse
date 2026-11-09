import AuthenticationServices
import UIKit

@MainActor
final class OneRepSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var current: OneRepSignIn?
    private let anchor: UIWindow
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    private init(anchor: UIWindow) {
        self.anchor = anchor
    }

    static func authorize() async throws -> OneRepGrant {
        try Task.checkCancellation()
        guard current == nil else { throw OneRepSignInError.alreadySigningIn }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let anchor = windows.first(where: { $0.activationState == .foregroundActive && $0.keyWindow != nil })?.keyWindow else {
            throw OneRepSignInError.couldNotStart
        }
        let transaction = try OneRepAuthorization()
        let flow = OneRepSignIn(anchor: anchor)
        current = flow
        defer { current = nil }
        let url = try await flow.open(transaction.authorizationURL(clientID: OneRepPublicClient.id))
        try Task.checkCancellation()
        let code = try transaction.code(from: url)
        return try await OneRepGrant.exchange(code: code, verifier: transaction.verifier, redirectURI: OneRepAuthorization.redirectURI)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }

    private func open(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else { complete(.failure(CancellationError())); return }
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: OneRepAuthorization.callbackScheme) { [weak self] callback, error in
                    Task { @MainActor in
                        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                            self?.complete(.failure(CancellationError()))
                        } else if let error {
                            self?.complete(.failure(error))
                        } else if let callback {
                            self?.complete(.success(callback))
                        } else {
                            self?.complete(.failure(OneRepSignInError.invalidCallback))
                        }
                    }
                }
                self.session = session
                session.presentationContextProvider = self
                if !session.start() { complete(.failure(OneRepSignInError.couldNotStart)) }
            }
        } onCancel: {
            Task { @MainActor in
                self.session?.cancel()
                self.complete(.failure(CancellationError()))
            }
        }
    }

    private func complete(_ result: Result<URL, Error>) {
        let pending = continuation
        continuation = nil
        session = nil
        pending?.resume(with: result)
    }
}
