import Foundation
import Security
import LocalAuthentication
import CryptoKit
import NIOSSH

/// Per-Mac account passwords (used for Screen Sharing, and for SSH on Macs
/// paired with password auth). This-device-only, never synced.
enum Keychain {
    private static let service = "com.charlieliu.homerow.password"

    static func password(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, for id: UUID) {
        deletePassword(for: id)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(password.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func deletePassword(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// The on-device ED25519 identity ("home-row-ed25519").
///
/// The private key is stored in the Keychain behind biometric access control,
/// so every use of it goes through Face ID / Touch ID (falling back to the
/// device passcode). On a device with no passcode set, the Keychain refuses
/// access-controlled items; in that case the key is stored without the gate
/// and `isBiometricallyProtected` reports false so the Keys screen can say so.
enum SSHIdentity {
    static let name = "home-row-ed25519"
    private static let service = "com.charlieliu.homerow.identity"
    private static let publicKeyDefaultsKey = "identity.publicKey"
    private static let protectedDefaultsKey = "identity.protected"

    /// OpenSSH public key line, safe to show and copy. Stored outside the
    /// Keychain so showing it never needs Face ID.
    static var publicKeyLine: String? {
        UserDefaults.standard.string(forKey: publicKeyDefaultsKey)
    }

    static var exists: Bool { publicKeyLine != nil }

    static var isBiometricallyProtected: Bool {
        UserDefaults.standard.bool(forKey: protectedDefaultsKey)
    }

    static var fingerprint: String? {
        publicKeyLine.flatMap(HostKeyTrust.fingerprint(ofOpenSSHKey:))
    }

    @discardableResult
    static func generate() throws -> String {
        delete()
        let key = Curve25519.Signing.PrivateKey()
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecValueData as String: key.rawRepresentation,
        ]
        var protected = false
        if let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil) {
            attributes[kSecAttrAccessControl as String] = access
            protected = SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        }
        if !protected {
            attributes.removeValue(forKey: kSecAttrAccessControl as String)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }

        let device = sanitizedDeviceName()
        let line = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
            + " \(name)@\(device)"
        UserDefaults.standard.set(line, forKey: publicKeyDefaultsKey)
        UserDefaults.standard.set(protected, forKey: protectedDefaultsKey)
        return line
    }

    /// Loads the private key. Prompts for Face ID / Touch ID when protected.
    /// Call off the main actor; the Keychain blocks while the prompt is up.
    static func load(reason: String) throws -> Curve25519.Signing.PrivateKey {
        let context = LAContext()
        context.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status == errSecUserCanceled || status == errSecAuthFailed {
                throw IdentityError.cancelled
            }
            throw IdentityError.missing
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: publicKeyDefaultsKey)
        UserDefaults.standard.removeObject(forKey: protectedDefaultsKey)
    }

    enum IdentityError: LocalizedError {
        case cancelled, missing
        var errorDescription: String? {
            switch self {
            case .cancelled: "Unlocking the SSH key was cancelled."
            case .missing: "This phone has no SSH key yet. Create one in Settings → SSH keys."
            }
        }
    }

    private static func sanitizedDeviceName() -> String {
        // UIDevice.name is generic on modern iOS without an entitlement; use
        // the model so the authorized_keys comment is still recognizable.
        "iphone-duo"
    }
}
