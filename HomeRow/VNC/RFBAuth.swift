import Foundation
import CommonCrypto
import CryptoKit
import BigInt

/// The two RFB security types Home Row speaks.
enum RFBAuth {
    /// Security type 30, "Apple Remote Desktop" Diffie-Hellman. This is what
    /// macOS Screen Sharing uses to sign in with a macOS *account* (username +
    /// password), so no separate VNC password is needed.
    ///
    /// Wire format, after the client selects type 30:
    ///   server → generator(u16) keyLength(u16) prime[keyLength] serverPublic[keyLength]
    ///   client → AES-128-ECB(MD5(sharedSecret), credentials[128]) clientPublic[keyLength]
    /// where credentials = username\0 padded to 64 + password\0 padded to 64,
    /// with the padding filled from a CSPRNG.
    static func appleDH(socket: RFBSocket, username: String, password: String) async throws {
        let generator = BigUInt(try await socket.u16())
        let keyLength = Int(try await socket.u16())
        guard (16...1024).contains(keyLength) else { throw RFBError.protocolError("bad ARD key length") }
        let prime = BigUInt(Data(try await socket.read(keyLength)))
        let serverPublic = BigUInt(Data(try await socket.read(keyLength)))

        let privateKey = BigUInt(Data(randomBytes(keyLength))) % prime
        let clientPublic = generator.power(privateKey, modulus: prime)
        let shared = serverPublic.power(privateKey, modulus: prime)

        let secret = Array(Insecure.MD5.hash(data: leftPad(shared.serialize(), to: keyLength)))

        var credentials = randomBytes(128)
        func place(_ string: String, at start: Int) {
            let bytes = Array(string.utf8.prefix(63))
            for (i, b) in bytes.enumerated() { credentials[start + i] = b }
            credentials[start + bytes.count] = 0
        }
        place(username, at: 0)
        place(password, at: 64)

        let encrypted = try ecb(algorithm: CCAlgorithm(kCCAlgorithmAES128), key: secret, data: credentials)
        socket.write(encrypted + leftPad(clientPublic.serialize(), to: keyLength))
    }

    /// Security type 2, classic VNC password (the optional "VNC viewers may
    /// control screen with password" setting). DES with bit-reversed key bytes.
    static func vncPassword(socket: RFBSocket, password: String) async throws {
        let challenge = Array(try await socket.read(16))
        socket.write(try vncResponse(challenge: challenge, password: password))
    }

    static func vncResponse(challenge: [UInt8], password: String) throws -> [UInt8] {
        var key = Array(password.utf8.prefix(8))
        key += [UInt8](repeating: 0, count: 8 - key.count)
        key = key.map(reverseBits)
        return try ecb(algorithm: CCAlgorithm(kCCAlgorithmDES), key: key, data: challenge)
    }

    private static func ecb(algorithm: CCAlgorithm, key: [UInt8], data: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + 16)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), algorithm, CCOptions(kCCOptionECBMode),
                             key, key.count, nil, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw RFBError.protocolError("cipher failed (\(status))") }
        return Array(out.prefix(moved))
    }

    private static func reverseBits(_ b: UInt8) -> UInt8 {
        var v = b, r: UInt8 = 0
        for _ in 0..<8 { r = (r << 1) | (v & 1); v >>= 1 }
        return r
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }

    private static func leftPad(_ data: Data, to length: Int) -> [UInt8] {
        let bytes = Array(data)
        if bytes.count >= length { return Array(bytes.suffix(length)) }
        return [UInt8](repeating: 0, count: length - bytes.count) + bytes
    }
}

enum RFBError: LocalizedError {
    case protocolError(String)
    case authFailed(String)
    case unsupportedSecurity([UInt8])
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .protocolError(let m): "Screen Sharing protocol error: \(m)"
        case .authFailed(let m): m.isEmpty ? "The Mac didn’t accept that username or password." : m
        case .unsupportedSecurity(let types):
            "This Mac only offers sign-in methods Home Row doesn’t support (\(types.map(String.init).joined(separator: ", "))). In Screen Sharing settings, turn on “VNC viewers may control screen with password” as a fallback."
        case .refused(let m): m
        }
    }
}
