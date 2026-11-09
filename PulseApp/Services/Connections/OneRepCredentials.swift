import Foundation
import Security

@MainActor
enum OneRepCredentials {
    private(set) static var connectionID = UUID()
    private static var renewal: Task<String, Error>?
    private static var revocation: Task<Void, Never>?
    private static var pendingStorage: OneRepGrant?

    private enum Stored {
        case legacy(String)
        case oauth(OneRepGrant)

        var token: String {
            switch self {
            case .legacy(let key): key
            case .oauth(let grant): grant.accessToken
            }
        }
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.pulseplanner.onerep",
            kSecAttrAccount as String: "personal-key",
            kSecAttrSynchronizable as String: false
        ]
    }

    static func load() throws -> String? { try stored()?.token }

    static func validToken() async throws -> String? {
        // The device can lock between the network response and the Keychain write.
        if let replacement = pendingStorage {
            try persist(replacement)
            pendingStorage = nil
        }
        guard let current = try stored() else { return nil }
        guard case .oauth(let grant) = current, grant.expiresAt.timeIntervalSinceNow < 60 else {
            return current.token
        }
        if let renewal { return try await renewal.value }
        let owner = connectionID
        // A refresh token can be exchanged exactly once. Finish persisting its successor
        // even if the original screen disappears while the request is running.
        let task = Task { @MainActor () throws -> String in
            defer { if connectionID == owner { renewal = nil } }
            do {
                let next = try await grant.renewed()
                guard connectionID == owner else { throw CancellationError() }
                pendingStorage = next
                try persist(next)
                pendingStorage = nil
                return next.accessToken
            } catch OneRepAPIError.unauthorized {
                if connectionID == owner { try clearLocal() }
                throw OneRepAPIError.unauthorized
            }
        }
        renewal = task
        return try await task.value
    }

    static func saveGrant(_ grant: OneRepGrant) throws {
        try persist(grant)
        invalidate()
    }

    private static func persist(_ grant: OneRepGrant) throws {
        try write(JSONEncoder().encode(grant))
    }

    private static func stored() throws -> Stored? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
        }
        if data.first == Character("{").asciiValue {
            return .oauth(try JSONDecoder().decode(OneRepGrant.self, from: data))
        }
        guard let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
        }
        return .legacy(key)
    }

    private static func write(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let item = query.merging(attributes) { _, value in value }
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(query as CFDictionary, attributes as CFDictionary))
        } else {
            try check(status)
        }
    }

    static func delete() throws {
        let previous = try? stored()
        let pending = pendingStorage
        try clearLocal()
        if let pending {
            scheduleRevocation(pending)
        } else if case .oauth(let grant) = previous {
            scheduleRevocation(grant)
        }
    }

    static func discard(_ grant: OneRepGrant) {
        // OneRep revokes by user and client, not by individual token pair.
        // A failed replacement must preserve the existing signed-in account.
        do {
            if try stored() == nil { scheduleRevocation(grant) }
        } catch { }
    }

    static func awaitPendingRevocation() async { await revocation?.value }

    private static func scheduleRevocation(_ grant: OneRepGrant) {
        let predecessor = revocation
        revocation = Task {
            await predecessor?.value
            try? await grant.revoke()
        }
    }

    private static func invalidate() {
        connectionID = UUID()
        renewal = nil
        pendingStorage = nil
    }

    private static func clearLocal() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
        invalidate()
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
