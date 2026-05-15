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

    func clear() {
        defaults.removeObject(forKey: "username")
        defaults.removeObject(forKey: "uuid")
        defaults.removeObject(forKey: "sessionToken")
        deletePassword()
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
