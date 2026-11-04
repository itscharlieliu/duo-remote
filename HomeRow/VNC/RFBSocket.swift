import Foundation
import Network

/// A TCP socket with exact-length async reads, for the RFB protocol.
/// Reads are only ever issued from the client's single decode task.
final class RFBSocket: @unchecked Sendable {
    enum Failure: LocalizedError {
        case closed
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .closed: "The Mac closed the Screen Sharing connection."
            case .failed(let m): m
            }
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "homerow.rfb.socket")
    private var buffer = [UInt8]()
    private var offset = 0
    private(set) var bytesReceived = 0
    let host: String
    private let openLock = NSLock()
    private var isOpen = false

    init(host: String, port: Int) {
        self.host = host
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
        }
        // No interface restriction here: LANGuard has already checked that
        // `host` is a private/VPN address. Prohibiting cellular would also
        // block a VPN tunnel that rides over cellular, since Network.framework
        // judges the path by the tunnel's underlying interface.
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 5900,
            using: params)
    }

    /// Connects, or returns at once if already connected (so a caller can
    /// open the socket itself to pick an address, then hand it to `RFBClient`).
    func open(timeout: TimeInterval = 10) async throws {
        if openLock.withLock({ isOpen }) { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() {
                        self.openLock.withLock { self.isOpen = true }
                        continuation.resume()
                    }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: Failure.failed(Self.describe(error))) }
                case .waiting(let error):
                    if once.claim() { continuation.resume(throwing: Failure.failed(Self.describe(error))) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: Failure.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() {
                    continuation.resume(throwing: Failure.failed("Timed out reaching Screen Sharing. Is the Mac awake?"))
                }
            }
        }
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .ECONNREFUSED {
            return "Screen Sharing is off on this Mac. Turn it on in System Settings → General → Sharing."
        }
        return "Couldn’t reach Screen Sharing: \(error.localizedDescription)"
    }

    func close() { connection.cancel() }

    // MARK: Reading

    func read(_ count: Int) async throws -> ArraySlice<UInt8> {
        while buffer.count - offset < count {
            try await fill(minimum: count - (buffer.count - offset))
        }
        let slice = buffer[offset..<(offset + count)]
        offset += count
        return slice
    }

    func u8() async throws -> UInt8 { try await read(1).first! }

    func u16() async throws -> UInt16 {
        let b = try await read(2)
        return UInt16(b[b.startIndex]) << 8 | UInt16(b[b.startIndex + 1])
    }

    func u32() async throws -> UInt32 {
        let b = try await read(4)
        let s = b.startIndex
        return UInt32(b[s]) << 24 | UInt32(b[s + 1]) << 16 | UInt32(b[s + 2]) << 8 | UInt32(b[s + 3])
    }

    func s32() async throws -> Int32 { Int32(bitPattern: try await u32()) }

    func skip(_ count: Int) async throws {
        var remaining = count
        while remaining > 0 {
            let chunk = min(remaining, 1 << 20)
            _ = try await read(chunk)
            remaining -= chunk
        }
    }

    private func fill(minimum: Int) async throws {
        // Compact before growing so the buffer doesn't creep.
        if offset > 0 && offset > buffer.count / 2 {
            buffer.removeSubrange(0..<offset)
            offset = 0
        }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(minimum, 1 << 18)) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: Failure.failed(error.localizedDescription))
                } else if isComplete {
                    continuation.resume(throwing: Failure.closed)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
        bytesReceived += data.count
        buffer.append(contentsOf: data)
    }

    // MARK: Writing

    func write(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}

extension Array where Element == UInt8 {
    mutating func appendU16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func appendU32(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }
}
