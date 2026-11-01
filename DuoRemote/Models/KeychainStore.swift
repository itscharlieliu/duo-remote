import Foundation
import Security

/// Passwords live in the Keychain, never in UserDefaults, logs, or the host list.
/// One entry per host id, namespaced so SSH and VNC passwords never collide.
enum KeychainStore {
    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.duoremote.passwords",
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ password: String, kind: PasswordKind, hostID: UUID) {
        let account = "\(kind.rawValue):\(hostID.uuidString)"
        guard let data = password.data(using: .utf8) else { return }
        var q = query(account: account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(query(account: account) as CFDictionary, update as CFDictionary)
        }
    }

    static func read(kind: PasswordKind, hostID: UUID) -> String? {
        var q = query(account: "\(kind.rawValue):\(hostID.uuidString)")
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(kind: PasswordKind, hostID: UUID) {
        SecItemDelete(query(account: "\(kind.rawValue):\(hostID.uuidString)") as CFDictionary)
    }
}

enum PasswordKind: String {
    case ssh
    case vnc
}
