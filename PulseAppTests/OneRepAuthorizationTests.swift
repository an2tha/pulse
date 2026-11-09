import CryptoKit
import Foundation
import Testing

@testable import Pulse

@Suite struct OneRepAuthorizationTests {
    @Test func signInUsesIndependentStateAndPKCE() throws {
        let first = try OneRepAuthorization()
        let second = try OneRepAuthorization()
        #expect(Set([first.state, first.verifier, second.state, second.verifier]).count == 4)
        let url = first.authorizationURL(clientID: "pulse-test")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "https" && parts.host == "chatty-panda-144.convex.site" && parts.path == "/oauth/authorize")
        let digest = Data(SHA256.hash(data: Data(first.verifier.utf8))).base64EncodedString()
        let challenge = digest.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
        let expected = [
            "response_type": "code", "client_id": "pulse-test", "redirect_uri": OneRepAuthorization.redirectURI,
            "state": first.state, "code_challenge_method": "S256", "code_challenge": challenge, "scope": "read write"
        ]
        for (name, value) in expected {
            #expect(parts.queryItems?.filter { $0.name == name }.compactMap(\.value) == [value])
        }
        #expect((43...128).contains(first.verifier.utf8.count))
        #expect(!url.absoluteString.contains(first.verifier))
    }

    @Test func acceptsBoundCodeAndRecognizesDenial() throws {
        let flow = try OneRepAuthorization()
        let base = OneRepAuthorization.redirectURI + "?state=" + flow.state
        let approved = try #require(URL(string: base + "&code=abc%2Bdef"))
        #expect(try flow.code(from: approved) == "abc+def")
        let denied = try #require(URL(string: base + "&error=access_denied"))
        #expect(throws: CancellationError.self) { try flow.code(from: denied) }
    }

    @Test func rejectsMismatchedAmbiguousOrReplayedCallbacks() throws {
        let flow = try OneRepAuthorization()
        let base = OneRepAuthorization.redirectURI
        let state = flow.state
        let urls = [
            base + "?state=" + (try OneRepAuthorization()).state + "&code=other-session",
            base + "?code=missing-state",
            base + "?state=" + state,
            base + "?state=" + state + "&code=",
            base + "?state=" + state + "&code=one&code=two",
            base + "?state=" + state + "&state=" + state + "&code=one",
            base + "?state=" + state + "&error=access_denied&code=one",
            base + "?state=wrong&error=access_denied",
            base + "?state=" + state + "&code=one#fragment",
            base + "/extra?state=" + state + "&code=one",
            "https://oauth/onerep?state=" + state + "&code=one",
            "app.pulseplanner.pulse://other/onerep?state=" + state + "&code=one",
            "app.pulseplanner.pulse://user@oauth/onerep?state=" + state + "&code=one"
        ]
        for rawURL in urls {
            let url = try #require(URL(string: rawURL))
            #expect(throws: OneRepSignInError.self) { try flow.code(from: url) }
        }
    }
}
