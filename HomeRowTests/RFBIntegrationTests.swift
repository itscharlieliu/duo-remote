import XCTest
import CoreGraphics
@testable import HomeRow

/// Runs against scratch `fake_rfb.py` when TEST_RUNNER_HOMEROW_RFB_PORT is
/// set: Apple DH sign-in, ServerInit, a ZRLE frame, the cursor, and input
/// round-tripped back as cut text.
final class RFBIntegrationTests: XCTestCase {

    @MainActor
    func testAppleSignInFrameCursorAndInput() async throws {
        guard let port = ProcessInfo.processInfo.environment["HOMEROW_RFB_PORT"].flatMap(Int.init) else {
            throw XCTSkip("No fake RFB server configured")
        }
        var events: [RFBEvent] = []
        let client = RFBClient(host: "127.0.0.1", port: port,
                               credentials: .init(username: "tester", password: "s3cret"),
                               quality: .high) { events.append($0) }
        client.start()
        defer { client.stop() }

        try await waitFor { events.contains { if case .frame = $0 { true } else { false } } }

        guard case .connected(let name, let w, let h)? = events.first(where: { if case .connected = $0 { true } else { false } }) else {
            return XCTFail("no connected event: \(events)")
        }
        XCTAssertEqual(name, "Fake Mac")
        XCTAssertEqual(w, 200)
        XCTAssertEqual(h, 100)

        // Left tile red, right tiles blue.
        guard case .frame(let image)? = events.last(where: { if case .frame = $0 { true } else { false } }) else { return }
        XCTAssertEqual(rgb(image, x: 10, y: 10), [255, 0, 0])
        XCTAssertEqual(rgb(image, x: 150, y: 90), [0, 0, 255])

        let cursor = events.compactMap { e -> (CGImage?, CGPoint)? in
            if case .cursor(let img, let hot) = e { return (img, hot) } else { return nil }
        }.first
        XCTAssertEqual(cursor?.1, CGPoint(x: 1, y: 2))
        XCTAssertEqual(cursor?.0?.width, 2)

        client.pointer(x: 10, y: 20, buttons: 1)
        client.key(Keysym.command, down: true)
        client.clipboard("héllo")
        try await waitFor {
            let clips = events.compactMap { e -> String? in if case .clipboard(let t) = e { t } else { nil } }
            return clips.contains("ptr 10,20 1") && clips.contains("key 0xffeb 1") && clips.contains("cut héllo")
        }
    }

    @MainActor
    func testWrongPasswordIsReported() async throws {
        guard let port = ProcessInfo.processInfo.environment["HOMEROW_RFB_PORT"].flatMap(Int.init) else {
            throw XCTSkip("No fake RFB server configured")
        }
        var failure: Error?
        let client = RFBClient(host: "127.0.0.1", port: port,
                               credentials: .init(username: "tester", password: "nope"),
                               quality: .adaptive) { if case .failed(let e) = $0 { failure = e } }
        client.start()
        defer { client.stop() }
        try await waitFor { failure != nil }
        guard case RFBError.authFailed(let reason)? = failure as? RFBError else {
            return XCTFail("expected authFailed, got \(String(describing: failure))")
        }
        XCTAssertTrue(reason.contains("bad credentials"))
    }

    private func rgb(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Array(px.prefix(3))
    }

    @MainActor
    private func waitFor(timeout: Double = 8, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
