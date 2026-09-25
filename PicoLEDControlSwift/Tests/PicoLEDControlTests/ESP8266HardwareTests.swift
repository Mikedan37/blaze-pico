import XCTest
import Combine
@testable import PicoLEDControlLib

/// Real-hardware protocol validation against firmware/esp8266-validation.
/// Skipped unless BLAZE_HW_PORT is set, so `swift test` and CI stay hardware-free.
///
///   BLAZE_HW_PORT=/dev/cu.usbserial-0001 swift test --filter ESP8266HardwareTests
///   BLAZE_HW_PORT=... BLAZE_HW_EXPECT_PROTOCOL=1 swift test --filter ESP8266HardwareTests   (proto1 build flashed)
///   BLAZE_HW_PORT=... BLAZE_HW_RESET_TEST=1 swift test --filter test08   (press RST when told)
final class ESP8266HardwareTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var port: String!
    private var session: PicoSession!
    private var bag = Set<AnyCancellable>()
    private var acks: [AckEvent] = []
    private var errors: [String] = []
    private let lock = NSLock()

    private var expectsProtocol1: Bool { env["BLAZE_HW_EXPECT_PROTOCOL"] == "1" }

    override func setUpWithError() throws {
        guard let p = env["BLAZE_HW_PORT"] else { throw XCTSkip("BLAZE_HW_PORT not set (hardware test)") }
        port = p
    }

    override func tearDown() {
        bag.removeAll()
        session?.disconnect()
        session = nil
    }

    // MARK: - helpers

    private func connect() async throws {
        session = PicoSession(portPath: port)
        session.events.sink { [weak self] event in
            guard let self = self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            switch event {
            case .ack(let a): self.acks.append(a)
            case .error(let e): self.errors.append(e.message)
            default: break
            }
        }.store(in: &bag)
        try await session.connect()
    }

    private func wait(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    private func ackTraces() -> [UInt64] { lock.lock(); defer { lock.unlock() }; return acks.map(\.traceID) }
    private func errorLines() -> [String] { lock.lock(); defer { lock.unlock() }; return errors }
    private var red: Bool? { session.lastKnownGPIOState?["R"] }

    /// STATUS over the text path; returns the key=value fields.
    private func status() async throws -> [String: String] {
        let line = try await session.sendTextCommand("STATUS", responsePrefix: "STATUS:", timeoutMs: 2000) ?? ""
        var fields: [String: String] = [:]
        for part in line.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        return fields
    }

    /// A command frame with one byte changed and, optionally, the CRC recomputed.
    private func frame(trace: UInt64, command: UInt8, value: UInt8,
                       mutate: ((inout Data) -> Void)? = nil, reseal: Bool = true) -> Data {
        var f = PicoWire.serialFrame(PicoWire.commandPacket(
            packetNumber: 900, command: PicoCommandV1(traceID: trace, command: command, value: value)))
        mutate?(&f)
        if reseal {
            let crc = PicoWire.crc32(f.subdata(in: 4..<(f.count - 4)))
            f.replaceSubrange((f.count - 4)..<f.count, with: withUnsafeBytes(of: crc.bigEndian) { Data($0) })
        }
        return f
    }

    // MARK: - checks (numbers refer to Docs/HARDWARE_TEST_PLAN.md)

    /// #1, #2: boots, handshake, protocol 2 accepted.
    func test01_Handshake() async throws {
        if expectsProtocol1 { throw XCTSkip("proto1 build flashed") }
        try await connect()
        XCTAssertEqual(session.compatibility, .compatible(2))
        XCTAssertTrue(session.isReady)
        XCTAssertEqual(session.deviceCapabilities?.model, "BLAZE_ESP8266_VALIDATION")
    }

    /// #3-#7: a real BlazeBinary command changes GPIO2, ACK carries the same trace, STATE_CHANGE matches.
    func test02_CommandDrivesLEDWithTraceCorrelation() async throws {
        if expectsProtocol1 { throw XCTSkip("proto1 build flashed") }
        try await connect()
        let before = try await status()

        let on: UInt64 = 0x0123_4567_89AB_CDEF
        try await session.sendCommand(commandID: .red, value: 1, traceID: on)
        XCTAssertTrue(wait { self.ackTraces().contains(on) }, "no ACK for trace \(on)")
        XCTAssertTrue(wait { self.red == true }, "STATE_CHANGE did not report R=1")

        let off: UInt64 = 0x0123_4567_89AB_CDF0
        try await session.sendCommand(commandID: .red, value: 0, traceID: off)
        XCTAssertTrue(wait { self.ackTraces().contains(off) })
        XCTAssertTrue(wait { self.red == false })

        let after = try await status()
        XCTAssertEqual(Int(after["frames_ok"] ?? "") ?? -1, (Int(before["frames_ok"] ?? "") ?? 0) + 2,
                       "device should count exactly the two binary commands")
    }

    /// #8: 20 commands in a row, every one acknowledged with its own trace.
    func test03_TwentyCommands() async throws {
        if expectsProtocol1 { throw XCTSkip("proto1 build flashed") }
        try await connect()
        var sent: [UInt64] = []
        for i in 0..<20 {
            let trace = UInt64(0xE5_8266_0000) + UInt64(i)
            sent.append(trace)
            try await session.sendCommand(commandID: .red, value: UInt8(i % 2), traceID: trace)
            XCTAssertTrue(wait { self.ackTraces().contains(trace) }, "command \(i) not acknowledged")
        }
        XCTAssertEqual(Set(ackTraces()).intersection(sent).count, 20)
        // Last command is i = 19, value 19 % 2 = 1 (on).
        XCTAssertTrue(wait { self.red == true }, "final state should match the last command (on)")
        try await session.sendCommand(commandID: .red, value: 0)
        XCTAssertTrue(wait { self.red == false })
    }

    /// #9: batch = several V1 frames in one write, all with the batch trace.
    func test04_Batch() async throws {
        if expectsProtocol1 { throw XCTSkip("proto1 build flashed") }
        try await connect()
        let trace: UInt64 = 0xBA7C_0000_0001
        try await session.sendBatch(commands: [(.red, 1), (.red, 0), (.red, 1)], traceID: trace)
        XCTAssertTrue(wait { self.ackTraces().filter { $0 == trace }.count == 3 }, "expected 3 ACKs with the batch trace")
        XCTAssertTrue(wait { self.red == true })
        try await session.sendCommand(commandID: .red, value: 0)
        XCTAssertTrue(wait { self.red == false })
    }

    /// #14, #15 + CRC: garbage, a corrupted byte, a wrong version and an invalid value execute nothing.
    func test05_MalformedInputExecutesNothing() async throws {
        if expectsProtocol1 { throw XCTSkip("proto1 build flashed") }
        try await connect()
        // Real state changes first, so the device's sequence is above 0 and the host records a
        // baseline (a no-op command right after a reset reports seq=0, which the host ignores).
        try await session.sendCommand(commandID: .red, value: 1)
        XCTAssertTrue(wait { self.red == true })
        try await session.sendCommand(commandID: .red, value: 0)
        XCTAssertTrue(wait { self.red == false })
        let before = try await status()
        let acksBefore = ackTraces().count

        var garbage = Data((0..<200).map { _ in UInt8.random(in: 0...255) })
        garbage.append(contentsOf: [0x0A])
        let badCRC = frame(trace: 0xBAD0_0001, command: 1, value: 1, mutate: { $0[30] ^= 0x01 }, reseal: false)
        let badVersion = frame(trace: 0xBAD0_0002, command: 1, value: 1, mutate: { $0[25] = 2 })
        let badValue = frame(trace: 0xBAD0_0003, command: 1, value: 2)

        for bytes in [garbage, badCRC, badVersion, badValue] {
            try session.writeBinaryFrames(bytes)
            usleep(400_000)  // longer than the firmware's 250 ms idle, so each is judged on its own
        }

        let after = try await status()
        XCTAssertEqual(after["frames_ok"], before["frames_ok"], "a malformed frame was executed")
        XCTAssertGreaterThanOrEqual((Int(after["frames_rejected"] ?? "") ?? 0) - (Int(before["frames_rejected"] ?? "") ?? 0), 3)
        XCTAssertEqual(ackTraces().count, acksBefore, "ACK sent for malformed input")
        XCTAssertEqual(red, false, "LED changed on malformed input")
        let joined = errorLines().joined(separator: "\n")
        XCTAssertTrue(joined.contains("BAD_CRC"), joined)
        XCTAssertTrue(joined.contains("UNSUPPORTED_VERSION"), joined)
        XCTAssertTrue(joined.contains("INVALID_VALUE"), joined)
    }

    /// #11, #13: reconnect by connecting again, then a command works.
    func test06_Reconnect() async throws {
        if expectsProtocol1 { throw XCTSkip("proto1 build flashed") }
        try await connect()
        session.disconnect()
        XCTAssertEqual(session.compatibility, .unknown)
        try await session.connect()
        XCTAssertEqual(session.compatibility, .compatible(2))
        let trace: UInt64 = 0x2EC0_0001
        try await session.sendCommand(commandID: .red, value: 0, traceID: trace)
        XCTAssertTrue(wait { self.ackTraces().contains(trace) })
    }

    /// #17: firmware reporting protocol 1 is refused before any binary byte is written.
    func test07_Protocol1FirmwareRefused() async throws {
        guard expectsProtocol1 else { throw XCTSkip("needs the proto1 build (BLAZE_HW_EXPECT_PROTOCOL=1)") }
        session = PicoSession(portPath: port)
        do {
            try await session.connect()
            XCTFail("host connected to protocol 1 firmware")
        } catch let error as PicoProtocolError {
            XCTAssertEqual(error, .incompatibleFirmware(reported: 1))
            print("[ESP8266] refused as expected: \(error.localizedDescription)")
        }
        XCTAssertFalse(session.isReady)

        // Ask the device, over plain text, how many binary frames it has ever seen.
        let serial = SerialPort(path: port)
        try serial.open(baudRate: 115200)
        defer { serial.close() }
        usleep(300_000)
        _ = try? serial.read(maxBytes: 4096, timeoutMs: 100)
        try serial.write(Data("STATUS\n".utf8))
        var text = ""
        let end = Date().addingTimeInterval(2)
        while Date() < end, !text.contains("frames_ok=") {
            text += String(decoding: try serial.read(maxBytes: 512, timeoutMs: 100), as: UTF8.self)
        }
        print("[ESP8266] device status after refusal: \(text.split(separator: "\n").first { $0.hasPrefix("STATUS:") } ?? "none")")
        XCTAssertTrue(text.contains("proto=1"), text)
        XCTAssertTrue(text.contains("frames_ok=0 frames_rejected=0"), "device received binary frames: \(text)")
    }

    /// Visible demo: show one command at every layer, the exact bytes sent, and the raw reply.
    /// Talks to the port directly so the printed bytes are exactly what goes on the wire.
    func test00_AWireTrace() async throws {
        guard env["BLAZE_HW_DEMO"] == "1", !expectsProtocol1 else { throw XCTSkip("set BLAZE_HW_DEMO=1") }
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }
        func out(_ label: String, _ text: String) { print("[WIRE] \(label.padding(toLength: 13, withPad: " ", startingAt: 0)) \(text)") }

        let serial = SerialPort(path: port)
        try serial.open(baudRate: 115200)
        defer { serial.close() }

        // Read lines until `stop` matches or the timeout passes; returns the non-heartbeat lines.
        func readLines(for seconds: Double, until stop: (String) -> Bool = { _ in false }) throws -> [String] {
            var text = "", lines: [String] = []
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                text += String(decoding: try serial.read(maxBytes: 512, timeoutMs: 100), as: UTF8.self)
                while let nl = text.firstIndex(of: "\n") {
                    let line = text[..<nl].trimmingCharacters(in: .whitespacesAndNewlines)
                    text = String(text[text.index(after: nl)...])
                    if line.isEmpty || line.hasPrefix("HEARTBEAT") { continue }
                    lines.append(line)
                    if stop(line) { return lines }
                }
            }
            return lines
        }

        _ = try readLines(for: 3) { $0 == "BLAZE_READY" }        // opening the port reboots this board
        try serial.write(Data("DEVICE_INFO\n".utf8))
        let info = try readLines(for: 2) { $0 == "DEVICE_INFO_END" }
        let proto = info.first { $0.hasPrefix("PROTOCOL=") } ?? "PROTOCOL=?"
        out("gate", "sent text \"DEVICE_INFO\" → board says \(proto)  (binary is only sent to PROTOCOL=2)")
        XCTAssertEqual(proto, "PROTOCOL=2")

        for (i, value) in [UInt8(1), 0].enumerated() {
            let trace: UInt64 = 0xDE30_00A0 + UInt64(i)
            let command = PicoCommandV1(traceID: trace, command: .red, value: value)
            let blaze = command.encoded()
            let frame = PicoWire.serialFrame(PicoWire.commandPacket(packetNumber: UInt32(i + 1), command: command))
            print("[WIRE]")
            out("command", "LED \(value == 1 ? "ON " : "OFF")   (command 1 = the Pico's \"RED\" slot, drives the blue LED here; value \(value); trace 0x\(String(format: "%016llX", trace)) = \(trace))")
            out("BlazeBinary", "\(hex(blaze))   ← PicoCommandV1: version · trace (8) · command · value, \(blaze.count) bytes")
            out("frame sent", "\(hex(frame.prefix(4)))  |  \(hex(frame.subdata(in: 4..<20)))")
            out("", "\(hex(frame.subdata(in: 20..<25)))  |  \(hex(frame.subdata(in: 25..<36)))  |  \(hex(frame.suffix(4)))")
            out("", "BLAZ sync | BlazeTransport header | DATA type+seq | PicoCommandV1 | CRC-32   = \(frame.count) bytes")
            try serial.write(frame)
            let reply = try readLines(for: 1.5) { $0.hasPrefix("STATE_CHANGE") }
            for line in reply { out("received", line) }
            XCTAssertTrue(reply.contains { $0.hasPrefix("ACK TRACE:\(trace) ") }, "no ACK for trace \(trace)")
            usleep(800_000)
        }
    }

    /// Visible demo: blink the blue LED through the full protocol stack, printing each ACK.
    func test00_DemoBlink() async throws {
        guard env["BLAZE_HW_DEMO"] == "1", !expectsProtocol1 else { throw XCTSkip("set BLAZE_HW_DEMO=1") }
        try await connect()
        print("[DEMO] connected: session \(String(format: "%08X", session.currentSessionID ?? 0)), protocol \(session.compatibility)")
        for i in 1...3 {
            for value: UInt8 in [1, 0] {
                let trace = UInt64(0xDE30_0000) + UInt64(i * 2 + Int(value))
                try await session.sendCommand(commandID: .red, value: value, traceID: trace)
                let acked = wait { self.ackTraces().contains(trace) }
                let state = wait { self.red == (value == 1) }
                print("[DEMO] LED \(value == 1 ? "ON " : "OFF")  trace=\(String(format: "%016llX", trace))  ACK \(acked ? "✓" : "✗")  state \(state ? "✓" : "✗")")
                XCTAssertTrue(acked && state)
                usleep(1_500_000)
            }
        }
    }

    /// #12: a reset starts a new session; the host re-checks the protocol and recovers.
    func test08_ResetStartsNewSession() async throws {
        guard env["BLAZE_HW_RESET_TEST"] == "1", !expectsProtocol1 else { throw XCTSkip("set BLAZE_HW_RESET_TEST=1 and press RST") }
        try await connect()
        session.events.sink { _ in }.store(in: &bag)
        let window = Double(env["BLAZE_HW_RESET_WAIT"] ?? "30") ?? 30
        print("[ESP8266] >>> press the RST button on the board now (\(Int(window)) s) <<<")
        let sawReset = wait(window) { self.session.compatibility != .compatible(2) }
        XCTAssertTrue(sawReset, "no new session seen")
        XCTAssertTrue(wait(10) { self.session.compatibility == .compatible(2) && self.session.isReady }, "did not recover")
        let trace: UInt64 = 0x5E55_0001
        try await session.sendCommand(commandID: .red, value: 0, traceID: trace)
        XCTAssertTrue(wait { self.ackTraces().contains(trace) })
    }
}
