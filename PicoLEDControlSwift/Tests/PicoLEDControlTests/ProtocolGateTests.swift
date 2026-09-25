import XCTest
import Darwin
@testable import PicoLEDControlLib

/// A fake Pico on the far side of a pseudo-terminal. PicoSession opens the pty's
/// slave path exactly like a real /dev/cu.usbmodem device. The fake answers the
/// text handshake with whatever protocol line a test sets, and records every
/// binary frame the host writes so tests can prove "zero binary writes".
final class FakePico {
    let slavePath: String
    private let master: Int32
    private let lock = NSLock()
    private var running = true
    private var thread: Thread?

    private var _protocolLine: String? = "PROTOCOL=2"
    private var _answersDeviceInfo = true
    private var _binaryFrames: [Data] = []
    private var _textLines: [String] = []

    /// Line sent inside DEVICE_INFO (nil = omit the PROTOCOL line entirely).
    var protocolLine: String? {
        get { lock.lock(); defer { lock.unlock() }; return _protocolLine }
        set { lock.lock(); _protocolLine = newValue; lock.unlock() }
    }
    /// false = firmware that never answers DEVICE_INFO.
    var answersDeviceInfo: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _answersDeviceInfo }
        set { lock.lock(); _answersDeviceInfo = newValue; lock.unlock() }
    }
    var binaryFrames: [Data] { lock.lock(); defer { lock.unlock() }; return _binaryFrames }
    var textLines: [String] { lock.lock(); defer { lock.unlock() }; return _textLines }

    init() throws {
        master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            throw NSError(domain: "FakePico", code: 1, userInfo: [NSLocalizedDescriptionKey: "pty setup failed"])
        }
        slavePath = String(cString: name)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        let t = Thread { [weak self] in self?.run() }
        thread = t
        t.start()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        usleep(60_000)
        close(master)
    }

    func emit(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count) }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func run() {
        var buffer = [UInt8]()
        var tick = 0
        while isRunning {
            var chunk = [UInt8](repeating: 0, count: 1024)
            let n = read(master, &chunk, chunk.count)
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]) }
            process(&buffer)

            // Readiness signals, repeated because the host flushes input on open.
            if tick % 3 == 0 {
                emit("BLAZE_READY\nHEARTBEAT: UPTIME:1 READY:1 R=0 G=0 Y=0 B=0 MR=0 MG=0 MB=0 S=90\n")
            }
            tick += 1
            usleep(20_000)
        }
    }

    private func process(_ buffer: inout [UInt8]) {
        while !buffer.isEmpty {
            if buffer.count >= 4, Array(buffer[0..<4]) == Array("BLAZ".utf8) {
                guard buffer.count >= 20 else { return }
                let total = 4 + 16 + (Int(buffer[18]) << 8 | Int(buffer[19])) + 4
                guard buffer.count >= total else { return }
                let frame = Data(buffer[0..<total])
                buffer.removeFirst(total)
                lock.lock(); _binaryFrames.append(frame); lock.unlock()
                if let decoded = try? PicoWire.decodeCommandFrame(frame) {
                    let c = decoded.command
                    if c.command == CommandID.status.rawValue {
                        emit("STATUS: ready=1 session=0000ABCD uptime=1 seq=0 fw=1.4.0 proto=2 model=BLAZE_PICO id=TEST\n")
                    } else {
                        emit("ACK TRACE:\(c.traceID) cmdID=\(c.command) value=\(c.value)\n")
                    }
                }
                continue
            }
            guard let newline = buffer.firstIndex(of: 0x0A) else {
                // Not a frame and no complete line yet; drop a lone stray byte only if it can't start "BLAZ".
                if buffer.first != 0x42 && buffer.count > 256 { buffer.removeFirst() }
                return
            }
            let line = String(decoding: buffer[0..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeFirst(newline + 1)
            lock.lock(); _textLines.append(line); lock.unlock()

            if line == "DEVICE_INFO" && answersDeviceInfo {
                var reply = "DEVICE_INFO_BEGIN\nMODEL=BLAZE_PICO\nFW_VERSION=1.4.0\n"
                if let p = protocolLine { reply += p + "\n" }
                reply += "DEVICE_ID=TEST\nMAX_CMD=128\nDEVICE_INFO_END\n"
                emit(reply)
            } else if line == "PINMAP" {
                emit("PINMAP_BEGIN\nPINMAP_END\n")
            }
        }
    }
}

final class ProtocolGateTests: XCTestCase {
    private var pico: FakePico!
    private var session: PicoSession!

    override func setUpWithError() throws {
        pico = try FakePico()
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

    private func decodedCommands() -> [PicoCommandV1] {
        pico.binaryFrames.compactMap { try? PicoWire.decodeCommandFrame($0).command }
    }

    // MARK: - connect()

    func testProtocol2BecomesReadyAndCommandsFlow() async throws {
        session = PicoSession(portPath: pico.slavePath)
        try await session.connect()
        XCTAssertEqual(session.compatibility, .compatible(2))
        XCTAssertTrue(session.isReady)

        let before = pico.binaryFrames.count   // STATUS probe, sent only after the gate passed
        try await session.sendCommand(commandID: .red, value: 1)
        XCTAssertTrue(wait { self.pico.binaryFrames.count == before + 1 })
        XCTAssertEqual(decodedCommands().last?.command, CommandID.red.rawValue)
        XCTAssertEqual(decodedCommands().last?.value, 1)
    }

    /// Protocol 1, missing, malformed, and future versions all fail closed with zero binary bytes written.
    func testIncompatibleFirmwareIsRejectedWithZeroBinaryWrites() async throws {
        let cases: [(line: String?, reported: Int)] = [
            ("PROTOCOL=1", 1),       // old firmware
            (nil, 0),                // no protocol line
            ("PROTOCOL=2abc", 0),    // malformed
            ("PROTOCOL=", 0),        // malformed
            ("PROTOCOL=3", 3),       // unsupported future version
        ]
        for c in cases {
            let fake = try FakePico()
            fake.protocolLine = c.line
            let s = PicoSession(portPath: fake.slavePath)
            do {
                try await s.connect()
                XCTFail("\(String(describing: c.line)): connect should throw")
            } catch let error as PicoProtocolError {
                XCTAssertEqual(error, .incompatibleFirmware(reported: c.reported), "\(String(describing: c.line))")
            }
            XCTAssertEqual(s.compatibility, .incompatible(reported: c.reported))
            XCTAssertFalse(s.isReady)
            XCTAssertFalse(s.isConnected)
            do {
                try await s.sendCommand(commandID: .red, value: 1)
                XCTFail("command accepted on incompatible firmware")
            } catch {}
            usleep(100_000)
            XCTAssertEqual(fake.binaryFrames.count, 0, "\(String(describing: c.line)): binary bytes were written")
            XCTAssertTrue(fake.textLines.contains("DEVICE_INFO"), "protocol must be read over the text path")
            s.disconnect()
            fake.stop()
        }
    }

    func testNoDeviceInfoReplyFailsClosed() async throws {
        pico.answersDeviceInfo = false
        session = PicoSession(portPath: pico.slavePath)
        do {
            try await session.connect()
            XCTFail("connect should throw")
        } catch let error as PicoProtocolError {
            XCTAssertEqual(error, .protocolUnknown)
        }
        XCTAssertEqual(session.compatibility, .unknown)
        XCTAssertFalse(session.isReady)
        XCTAssertEqual(pico.binaryFrames.count, 0)
    }

    func testIncompatibleErrorMessage() {
        XCTAssertEqual(
            PicoProtocolError.incompatibleFirmware(reported: 1).localizedDescription,
            "Incompatible Pico firmware protocol (device reports protocol 1). Host requires protocol 2. Reflash the device firmware.")
    }

    // MARK: - reconnect / new session

    func testReconnectToV1DeviceIsRejected() async throws {
        session = PicoSession(portPath: pico.slavePath)
        try await session.connect()
        XCTAssertTrue(session.isReady)
        session.disconnect()
        XCTAssertEqual(session.compatibility, .unknown, "compatibility must not survive disconnect")

        pico.protocolLine = "PROTOCOL=1"         // device was reflashed with old firmware
        let before = pico.binaryFrames.count
        do {
            try await session.connect()
            XCTFail("reconnect to v1 firmware should throw")
        } catch let error as PicoProtocolError {
            XCTAssertEqual(error, .incompatibleFirmware(reported: 1))
        }
        XCTAssertFalse(session.isReady)
        usleep(100_000)
        XCTAssertEqual(pico.binaryFrames.count, before, "binary bytes written to v1 firmware on reconnect")
    }

    func testV2ReconnectStillWorks() async throws {
        session = PicoSession(portPath: pico.slavePath)
        try await session.connect()
        session.disconnect()
        try await session.connect()
        XCTAssertEqual(session.compatibility, .compatible(2))
        XCTAssertTrue(session.isReady)
        let before = pico.binaryFrames.count
        try await session.sendCommand(commandID: .green, value: 1)
        XCTAssertTrue(wait { self.pico.binaryFrames.count == before + 1 })
    }

    /// Device reboots into old firmware while the event reader is running (new SESSION id).
    func testNewSessionOnV1FirmwareBlocksCommands() async throws {
        session = PicoSession(portPath: pico.slavePath)
        try await session.connect()
        pico.emit("SESSION:0000ABCD\n")
        usleep(200_000)
        XCTAssertTrue(session.isReady)

        pico.protocolLine = "PROTOCOL=1"
        let before = pico.binaryFrames.count
        pico.emit("SESSION:0000BEEF\n")

        XCTAssertTrue(wait { self.session.compatibility == .incompatible(reported: 1) },
                      "new session was not re-validated (got \(session.compatibility))")
        XCTAssertFalse(session.isReady)
        do {
            try await session.sendCommand(commandID: .red, value: 1)
            XCTFail("command accepted after reboot into v1 firmware")
        } catch {}

        // The single write path refuses even with the port open, so nothing queued
        // earlier can reach the device either.
        let frame = PicoWire.serialFrame(PicoWire.commandPacket(
            packetNumber: 99, command: PicoCommandV1(traceID: 1, command: .red, value: 1)))
        XCTAssertThrowsError(try session.writeBinaryFrames(frame)) {
            XCTAssertEqual($0 as? PicoProtocolError, .incompatibleFirmware(reported: 1))
        }
        usleep(100_000)
        XCTAssertEqual(pico.binaryFrames.count, before, "binary bytes written after reboot into v1 firmware")
    }

    /// Normal reboot into compatible firmware: commands pause, then resume after re-validation.
    func testNewSessionOnV2FirmwareRecovers() async throws {
        session = PicoSession(portPath: pico.slavePath)
        try await session.connect()
        pico.emit("SESSION:0000ABCD\n")
        usleep(200_000)
        let infoQueries = pico.textLines.filter { $0 == "DEVICE_INFO" }.count
        pico.emit("SESSION:0000CAFE\n")
        // Re-validation must actually happen (a new DEVICE_INFO round trip), then recover.
        XCTAssertTrue(wait { self.pico.textLines.filter { $0 == "DEVICE_INFO" }.count == infoQueries + 1 })
        XCTAssertTrue(wait { self.session.compatibility == .compatible(2) && self.session.isReady })
        let before = pico.binaryFrames.count
        try await session.sendCommand(commandID: .blue, value: 1)
        XCTAssertTrue(wait { self.pico.binaryFrames.count == before + 1 })
    }

    // MARK: - PicoLEDController (one-shot CLI path)

    func testControllerRefusesV1Firmware() throws {
        pico.protocolLine = "PROTOCOL=1"
        let controller = PicoLEDController(portPath: pico.slavePath)
        defer { controller.close() }
        XCTAssertThrowsError(try controller.sendBinaryCommand(commandID: .red, value: 1)) {
            XCTAssertEqual($0 as? PicoProtocolError, .incompatibleFirmware(reported: 1))
        }
        usleep(100_000)
        XCTAssertEqual(pico.binaryFrames.count, 0)
    }

    func testControllerSendsToV2Firmware() throws {
        let controller = PicoLEDController(portPath: pico.slavePath)
        defer { controller.close() }
        _ = try controller.sendBinaryCommand(commandID: .red, value: 1)
        XCTAssertTrue(wait { self.pico.binaryFrames.count == 1 })
        XCTAssertEqual(decodedCommands().first?.command, CommandID.red.rawValue)
    }
}
