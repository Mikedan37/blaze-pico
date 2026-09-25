import XCTest
@testable import PicoLEDControlLib

/// Session identity and state ordering, driven through the fake Pico (a pseudo-terminal).
/// Reproduces the hardware findings in firmware/esp8266-validation/FINDINGS.md.
final class SessionLifecycleTests: XCTestCase {
    private var pico: FakePico!
    private var session: PicoSession!

    override func setUpWithError() throws {
        pico = try FakePico()
        pico.sessionID = 0xAAAA_0001
    }

    override func tearDown() {
        session?.disconnect()
        pico?.stop()
    }

    private func wait(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    private func connect() async throws {
        session = PicoSession(portPath: pico.slavePath)
        try await session.connect()
    }

    private func stateChange(seq: Int, red: Bool) {
        pico.emit("STATE_CHANGE: trace=1 seq=\(seq) R=\(red ? 1 : 0) G=0 Y=0 B=0 MR=0 MG=0 MB=0 S=0\n")
    }

    private var red: Bool? { session.lastKnownGPIOState?["R"] }
    private var deviceInfoQueries: Int { pico.textLines.filter { $0 == "DEVICE_INFO" }.count }

    /// Bring the state to a known (seq, red) inside the current session.
    private func apply(seq: Int, red value: Bool) {
        stateChange(seq: seq, red: value)
        XCTAssertTrue(wait { self.red == value }, "seq=\(seq) R=\(value) was not applied")
    }

    // 1. The SESSION seen during the handshake becomes the accepted session.
    func testConnectAdoptsHandshakeSession() async throws {
        try await connect()
        XCTAssertEqual(session.currentSessionID, 0xAAAA_0001)
    }

    // 2. The same SESSION announced again is not a transition and keeps ordering state.
    func testSameSessionAgainIsNotATransition() async throws {
        try await connect()
        apply(seq: 5, red: true)
        let queries = deviceInfoQueries
        pico.emit("SESSION:AAAA0001\n")          // (the fake also re-announces it every ~60 ms)
        usleep(300_000)
        XCTAssertEqual(deviceInfoQueries, queries, "same session triggered a protocol re-check")
        XCTAssertEqual(session.compatibility, .compatible(2))
        stateChange(seq: 5, red: false)           // duplicate: ordering must not have been reset
        usleep(200_000)
        XCTAssertEqual(red, true)
    }

    // 3. A new SESSION after connect triggers the compatibility re-check (the ESP8266 RST case).
    func testFirstResetAfterConnectTriggersRecheck() async throws {
        try await connect()
        let queries = deviceInfoQueries
        pico.protocolLine = "PROTOCOL=1"          // rebooted into old firmware
        pico.sessionID = 0xBBBB_0002
        XCTAssertTrue(wait { self.session.compatibility == .incompatible(reported: 1) },
                      "reboot after connect was not treated as a new session (got \(session.compatibility))")
        XCTAssertEqual(deviceInfoQueries, queries + 1)
        XCTAssertEqual(session.currentSessionID, 0xBBBB_0002)
        XCTAssertFalse(session.isReady)
    }

    // 4. seq=0 is accepted: on a fresh connect, and as the first state of a new session.
    func testSequenceZeroAcceptedOnFreshConnect() async throws {
        try await connect()
        stateChange(seq: 0, red: true)
        XCTAssertTrue(wait { self.red == true }, "first STATE_CHANGE seq=0 was dropped")
    }

    func testSequenceZeroAcceptedInNewSession() async throws {
        try await connect()
        apply(seq: 7, red: true)
        pico.sessionID = 0xCCCC_0003
        XCTAssertTrue(wait { self.session.currentSessionID == 0xCCCC_0003 && self.session.isReady })
        stateChange(seq: 0, red: false)
        XCTAssertTrue(wait { self.red == false }, "seq=0 in the new session was rejected")
    }

    // 5. Within a session, equal or lower sequences are still rejected.
    func testEqualOrLowerSequenceRejectedWithinSession() async throws {
        try await connect()
        apply(seq: 5, red: true)
        stateChange(seq: 5, red: false)           // duplicate
        stateChange(seq: 3, red: false)           // out of order (previously accepted as a "reboot")
        usleep(300_000)
        XCTAssertEqual(red, true, "duplicate or out-of-order STATE_CHANGE was applied")
        apply(seq: 6, red: false)                 // newer still applies
    }

    // 6. Sequence state does not leak across sessions (either direction).
    func testSequenceStateDoesNotLeakAcrossSessions() async throws {
        try await connect()
        apply(seq: 40, red: true)
        pico.sessionID = 0xDDDD_0004
        XCTAssertTrue(wait { self.session.currentSessionID == 0xDDDD_0004 && self.session.isReady })
        apply(seq: 2, red: false)                 // low number, new session: accepted
        stateChange(seq: 1, red: true)            // lower within the NEW session: rejected
        usleep(300_000)
        XCTAssertEqual(red, false)
    }

    // 7. Events from the previous session stay stale. The serial link is one ordered stream,
    //    so everything sent before the new SESSION line belongs to the old session.
    func testPreviousSessionEventsRemainRejected() async throws {
        try await connect()
        apply(seq: 9, red: true)
        pico.emit("STATE_CHANGE: trace=1 seq=4 R=0 G=0 Y=0 B=0 MR=0 MG=0 MB=0 S=0\n"
                  + "SESSION:EEEE0005\n"
                  + "STATE_CHANGE: trace=1 seq=0 R=1 G=0 Y=0 B=0 MR=0 MG=0 MB=0 S=0\n")
        pico.sessionID = 0xEEEE_0005
        XCTAssertTrue(wait { self.session.currentSessionID == 0xEEEE_0005 })
        usleep(300_000)
        XCTAssertEqual(red, true, "old-session seq=4 was applied, or new-session seq=0 was not")
    }

    // 8. Reconnect: same session keeps ordering; a different session starts fresh.
    func testReconnectToSameSessionKeepsOrdering() async throws {
        try await connect()
        apply(seq: 5, red: true)
        session.disconnect()
        try await session.connect()               // device still announces AAAA0001
        XCTAssertEqual(session.currentSessionID, 0xAAAA_0001)
        stateChange(seq: 5, red: false)           // same session: still a duplicate
        usleep(300_000)
        XCTAssertEqual(red, true)
        XCTAssertTrue(session.isReady)
    }

    func testReconnectToNewSessionStartsFresh() async throws {
        try await connect()
        apply(seq: 5, red: true)
        session.disconnect()
        pico.sessionID = 0xFFFF_0006              // device rebooted while disconnected
        try await session.connect()
        XCTAssertEqual(session.currentSessionID, 0xFFFF_0006)
        XCTAssertEqual(session.compatibility, .compatible(2))
        stateChange(seq: 0, red: false)
        XCTAssertTrue(wait { self.red == false })
    }

    /// Late join: the handshake showed no SESSION line, so the first one seen afterwards
    /// is a new session (firmware announces SESSION only when a session starts).
    func testLateJoinThenSessionAnnouncementIsANewSession() async throws {
        pico.sessionID = nil
        try await connect()
        XCTAssertNil(session.currentSessionID)
        let queries = deviceInfoQueries
        pico.sessionID = 0x1234_5678
        XCTAssertTrue(wait { self.session.currentSessionID == 0x1234_5678 && self.session.isReady })
        XCTAssertEqual(deviceInfoQueries, queries + 1)
    }
}
