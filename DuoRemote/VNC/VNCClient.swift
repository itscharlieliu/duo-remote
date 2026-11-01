import Foundation
import Network
import UIKit
import CommonCrypto

/// Minimal RFB 3.8 client, written for macOS Screen Sharing over the LAN.
///
/// Supported, deliberately narrow on purpose:
/// - Security: None (1) and VNC password auth (2, DES challenge/response).
///   macOS's Apple ARD auth (type 30, macOS-account login) is NOT supported
///   in v1 — see README for the one setting that makes a Mac work with this.
/// - Encodings: Raw (0) and CopyRect (1). macOS offers Raw, so this is enough
///   on a LAN; ZRLE/Tight would be the next performance step, not a correctness one.
/// - Pixel format: forced to 32bpp, 24-bit true colour, R16/G8/B0, so the
///   decode below is one fixed path instead of a generic pixel-format engine.
///
/// The session itself is not encrypted by RFB. That is why the app is LAN-only:
/// use it on a trusted home network, never pointed at a public address.
@MainActor
final class VNCClient: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
        case disconnected
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var image: UIImage?
    @Published private(set) var remoteSize: CGSize = .zero

    private var connection: NWConnection?
    private var reader: VNCReader?
    private var framebuffer: [UInt8] = []
    private var width: Int = 0
    private var height: Int = 0
    private var runTask: Task<Void, Never>?

    func connect(host: String, port: Int, password: String?) {
        disconnect()
        guard LANValidation.isPrivateOrLocal(host) else {
            state = .failed("LAN only: refusing a non-private host.")
            return
        }
        state = .connecting

        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        self.connection = connection
        let reader = VNCReader(connection: connection)
        self.reader = reader

        runTask = Task {
            do {
                connection.start(queue: .global(qos: .userInitiated))
                try await reader.waitForReady()
                try await handshake(reader: reader, password: password)
                await MainActor.run { self.state = .connected }
                try await messageLoop(reader: reader)
            } catch {
                await MainActor.run {
                    if self.state == .connecting || self.state == .connected {
                        self.state = .failed(Self.friendlyError(error))
                    }
                }
            }
        }
    }

    func disconnect() {
        runTask?.cancel()
        runTask = nil
        connection?.cancel()
        connection = nil
        reader = nil
        if state == .connecting || state == .connected {
            state = .disconnected
        }
    }

    // MARK: - Outbound input

    func sendPointer(x: Int, y: Int, buttons: UInt8) {
        guard state == .connected, let connection else { return }
        var data = Data()
        data.append(5)
        data.append(buttons)
        data.append(contentsOf: UInt16(clamping(x)).bigEndianBytes)
        data.append(contentsOf: UInt16(clamping(y)).bigEndianBytes)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func sendKey(down: Bool, keysym: UInt32) {
        guard state == .connected, let connection else { return }
        var data = Data()
        data.append(4)
        data.append(down ? 1 : 0)
        data.append(contentsOf: [0, 0])
        data.append(contentsOf: keysym.bigEndianBytes)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Tap a key: down then up, with any latched modifiers held by the caller.
    func tapKey(_ keysym: UInt32) {
        sendKey(down: true, keysym: keysym)
        sendKey(down: false, keysym: keysym)
    }

    // MARK: - Handshake

    private func handshake(reader: VNCReader, password: String?) async throws {
        let version = try await reader.readExactly(12)
        guard version.starts(with: Data("RFB ".utf8)) else {
            throw VNCError.protocolError("Not a VNC server.")
        }
        // We speak 3.8 regardless of whether the server offered 3.3–3.8;
        // macOS Screen Sharing speaks 3.8.
        try await reader.write(Data("RFB 003.008\n".utf8))

        let countByte = try await reader.readExactly(1)
        let count = Int(countByte[0])
        guard count > 0 else {
            let length = try await reader.readUInt32()
            let reason = try await reader.readExactly(Int(length))
            throw VNCError.authFailed(String(data: reason, encoding: .utf8) ?? "Server refused the connection.")
        }
        let types = try await reader.readExactly(count)

        if types.contains(2) {
            guard let password, !password.isEmpty else {
                throw VNCError.authFailed("This Mac requires a VNC password. Set it in the host, or enable VNC-password mode (see README).")
            }
            try await reader.write(Data([2]))
            let challenge = try await reader.readExactly(16)
            let response = try Self.vncAuthResponse(challenge: challenge, password: password)
            try await reader.write(response)
            let result = try await reader.readUInt32()
            guard result == 0 else {
                // RFB 3.8: a reason string follows a failed auth.
                let length = try await reader.readUInt32()
                let reason = try await reader.readExactly(Int(length))
                throw VNCError.authFailed(String(data: reason, encoding: .utf8) ?? "VNC password rejected.")
            }
        } else if types.contains(1) {
            try await reader.write(Data([1]))
            let result = try await reader.readUInt32()
            guard result == 0 else { throw VNCError.authFailed("Server rejected the connection.") }
        } else {
            throw VNCError.authFailed(
                "This Mac is not offering VNC-password auth. In System Settings > General > Sharing > Screen Sharing, turn on “VNC viewers may control screen with password”.")
        }

        // ClientInit: shared desktop.
        try await reader.write(Data([1]))

        // ServerInit.
        width = Int(try await reader.readUInt16())
        height = Int(try await reader.readUInt16())
        _ = try await reader.readExactly(16) // server pixel format; we override it below
        let nameLength = try await reader.readUInt32()
        _ = try await reader.readExactly(Int(nameLength))
        guard width > 0, height > 0, width <= 8192, height <= 8192 else {
            throw VNCError.protocolError("Implausible desktop size \(width)×\(height).")
        }
        framebuffer = [UInt8](repeating: 0, count: width * height * 4)
        await MainActor.run { self.remoteSize = CGSize(width: width, height: height) }

        // SetPixelFormat: 32bpp, depth 24, little-endian, true colour, R16/G8/B0.
        var format = Data([0, 0, 0, 0]) // message type 0 + padding
        format.append(contentsOf: [32, 24, 0, 1]) // bpp, depth, bigEndian, trueColour
        format.append(contentsOf: UInt16(255).bigEndianBytes) // redMax
        format.append(contentsOf: UInt16(255).bigEndianBytes) // greenMax
        format.append(contentsOf: UInt16(255).bigEndianBytes) // blueMax
        format.append(contentsOf: [16, 8, 0, 0, 0, 0]) // shifts + padding
        try await reader.write(format)

        // SetEncodings: Raw + CopyRect.
        var encodings = Data([2, 0])
        encodings.append(contentsOf: UInt16(2).bigEndianBytes)
        encodings.append(contentsOf: Int32(0).bigEndianBytes)
        encodings.append(contentsOf: Int32(1).bigEndianBytes)
        try await reader.write(encodings)

        try await requestUpdate(incremental: false, reader: reader)
    }

    private func requestUpdate(incremental: Bool, reader: VNCReader) async throws {
        var request = Data([3, incremental ? 1 : 0])
        request.append(contentsOf: UInt16(0).bigEndianBytes)
        request.append(contentsOf: UInt16(0).bigEndianBytes)
        request.append(contentsOf: UInt16(width).bigEndianBytes)
        request.append(contentsOf: UInt16(height).bigEndianBytes)
        try await reader.write(request)
    }

    // MARK: - Server messages

    private func messageLoop(reader: VNCReader) async throws {
        while !Task.isCancelled {
            let type = try await reader.readExactly(1)[0]
            switch type {
            case 0: // FramebufferUpdate
                _ = try await reader.readExactly(1) // padding
                let rectCount = Int(try await reader.readUInt16())
                for _ in 0..<rectCount {
                    let x = Int(try await reader.readUInt16())
                    let y = Int(try await reader.readUInt16())
                    let w = Int(try await reader.readUInt16())
                    let h = Int(try await reader.readUInt16())
                    let encoding = try await reader.readInt32()
                    switch encoding {
                    case 0: // Raw
                        let bytes = try await reader.readExactly(w * h * 4)
                        applyRaw(bytes: bytes, x: x, y: y, w: w, h: h)
                    case 1: // CopyRect
                        let srcX = Int(try await reader.readUInt16())
                        let srcY = Int(try await reader.readUInt16())
                        applyCopyRect(srcX: srcX, srcY: srcY, x: x, y: y, w: w, h: h)
                    default:
                        throw VNCError.protocolError("Unsupported rectangle encoding \(encoding).")
                    }
                }
                render()
                try await requestUpdate(incremental: true, reader: reader)
            case 1: // SetColourMapEntries (not expected with true colour)
                _ = try await reader.readExactly(1)
                _ = try await reader.readUInt16()
                let n = Int(try await reader.readUInt16())
                _ = try await reader.readExactly(n * 6)
            case 2: // Bell
                break
            case 3: // ServerCutText
                _ = try await reader.readExactly(3)
                let length = Int(try await reader.readUInt32())
                _ = try await reader.readExactly(length)
            default:
                throw VNCError.protocolError("Unknown server message type \(type).")
            }
        }
    }

    private func applyRaw(bytes: Data, x: Int, y: Int, w: Int, h: Int) {
        // Server bytes per pixel: B, G, R, pad. Framebuffer: R, G, B, A.
        bytes.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt8.self)
            for row in 0..<h {
                let destY = y + row
                guard destY < height else { continue }
                for col in 0..<w {
                    let destX = x + col
                    guard destX < width else { continue }
                    let s = (row * w + col) * 4
                    let d = (destY * width + destX) * 4
                    framebuffer[d] = src[s + 2]
                    framebuffer[d + 1] = src[s + 1]
                    framebuffer[d + 2] = src[s]
                    framebuffer[d + 3] = 255
                }
            }
        }
    }

    private func applyCopyRect(srcX: Int, srcY: Int, x: Int, y: Int, w: Int, h: Int) {
        let snapshot = framebuffer
        for row in 0..<h {
            for col in 0..<w {
                let sx = srcX + col, sy = srcY + row
                let dx = x + col, dy = y + row
                guard sx >= 0, sy >= 0, dx >= 0, dy >= 0, sx < width, sy < height, dx < width, dy < height else { continue }
                let s = (sy * width + sx) * 4
                let d = (dy * width + dx) * 4
                framebuffer[d] = snapshot[s]
                framebuffer[d + 1] = snapshot[s + 1]
                framebuffer[d + 2] = snapshot[s + 2]
                framebuffer[d + 3] = snapshot[s + 3]
            }
        }
    }

    private func render() {
        let w = width, h = height
        guard w > 0, h > 0 else { return }
        let pixels = framebuffer
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: w, height: h,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        self.image = UIImage(cgImage: image)
    }

    // MARK: - VNC password auth (DES)

    /// RFB VNC auth: password truncated/padded to 8 bytes, each byte's bits
    /// reversed, then DES-ECB encryption of the 16-byte challenge.
    static func vncAuthResponse(challenge: Data, password: String) throws -> Data {
        var key = [UInt8](password.utf8.prefix(8))
        while key.count < 8 { key.append(0) }
        key = key.map { reverseBits($0) }
        guard challenge.count == 16 else { throw VNCError.protocolError("Bad VNC challenge length.") }
        var output = [UInt8](repeating: 0, count: 16)
        var outputLength = 0
        let status = key.withUnsafeBytes { keyPtr in
            challenge.withUnsafeBytes { inputPtr in
                output.withUnsafeMutableBytes { outputPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, kCCKeySizeDES,
                        nil,
                        inputPtr.baseAddress, challenge.count,
                        outputPtr.baseAddress, output.count,
                        &outputLength)
                }
            }
        }
        guard status == kCCSuccess, outputLength == 16 else {
            throw VNCError.protocolError("VNC password encryption failed.")
        }
        return Data(output)
    }

    private static func reverseBits(_ byte: UInt8) -> UInt8 {
        var value = byte
        var result: UInt8 = 0
        for _ in 0..<8 {
            result = (result << 1) | (value & 1)
            value >>= 1
        }
        return result
    }

    private static func friendlyError(_ error: Error) -> String {
        if let vncError = error as? VNCError { return vncError.message }
        return error.localizedDescription.isEmpty ? "VNC connection failed." : error.localizedDescription
    }
}

enum VNCError: Error {
    case protocolError(String)
    case authFailed(String)
    var message: String {
        switch self {
        case .protocolError(let text), .authFailed(let text): return text
        }
    }
}

// MARK: - Buffered NWConnection reader

/// Small exact-read wrapper over NWConnection's callback API.
final class VNCReader: @unchecked Sendable {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func waitForReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .cancelled:
                    continuation.resume(throwing: VNCError.protocolError("Connection cancelled."))
                default:
                    break
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func readExactly(_ count: Int) async throws -> Data {
        if count == 0 { return Data() }
        var result = Data()
        while result.count < count {
            let chunk = try await receiveChunk(minimum: 1, maximum: count - result.count)
            guard !chunk.isEmpty else {
                throw VNCError.protocolError("Connection closed by the Mac.")
            }
            result.append(chunk)
        }
        return result
    }

    func readUInt8() async throws -> UInt8 { try await readExactly(1)[0] }

    func readUInt16() async throws -> UInt16 {
        let bytes = try await readExactly(2)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    func readUInt32() async throws -> UInt32 {
        let bytes = try await readExactly(4)
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    func readInt32() async throws -> Int32 { Int32(bitPattern: try await readUInt32()) }

    private func receiveChunk(minimum: Int, maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

private extension UInt16 {
    var bigEndianBytes: [UInt8] {
        let value = bigEndian
        return [UInt8(value >> 8), UInt8(value & 0xFF)]
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        let value = bigEndian
        return [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ]
    }
}

private extension Int32 {
    var bigEndianBytes: [UInt8] { UInt32(bitPattern: self).bigEndianBytes }
}
