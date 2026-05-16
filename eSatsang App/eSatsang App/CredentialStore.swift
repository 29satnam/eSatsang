import Foundation
import Security

struct CredentialStore {
    private let service = "com.silverseahog.esatsang.credentials"
    private let passwordAccount = "password"
    private let defaults = UserDefaults.standard

    var username: String? {
        defaults.string(forKey: "username")
    }

    var session: Session? {
        guard let username,
              let uuid = defaults.string(forKey: "uuid"),
              let token = defaults.string(forKey: "sessionToken"),
              !username.isEmpty,
              !uuid.isEmpty,
              !token.isEmpty else { return nil }

        return Session(username: username, uuid: uuid, sessionToken: token)
    }

    var hasSession: Bool { session != nil }

    func save(username: String, password: String, session: Session) throws {
        defaults.set(username, forKey: "username")
        defaults.set(session.uuid, forKey: "uuid")
        defaults.set(session.sessionToken, forKey: "sessionToken")
        try savePassword(password)
    }

    /// Full wipe — use only on explicit user-initiated logout.
    func clear() {
        defaults.removeObject(forKey: "username")
        defaults.removeObject(forKey: "uuid")
        defaults.removeObject(forKey: "sessionToken")
        deletePassword()
    }

    /// Clears only the session token. Username and Keychain password are kept
    /// so the login screen can re-authenticate without the user retyping anything.
    func clearSession() {
        defaults.removeObject(forKey: "uuid")
        defaults.removeObject(forKey: "sessionToken")
    }

    /// Returns the stored Keychain password, if any.
    func readPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: passwordAccount,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func savePassword(_ password: String) throws {
        let data = Data(password.utf8)
        deletePassword()

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: passwordAccount,
            kSecValueData as String:   data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ESatsangError.keychainFailed(status)
        }
    }

    private func deletePassword() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: passwordAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
