import XCTest
import BlazeBinary
@testable import PicoLEDControlLib

/// Checks the Swift side of the Mac -> Pico wire format against
/// firmware/tests/protocol/golden_frames.txt. The firmware C tests
/// (firmware/tests/protocol/test_protocol.c) check the same file, so every
/// vector here is proof that Swift-encoded bytes decode in C and C-encoded
/// bytes decode in Swift.
final class PicoWireTests: XCTestCase {

    private func goldenLines(_ kind: String) throws -> [[String]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("firmware/tests/protocol/golden_frames.txt")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { $0.split(separator: " ").map(String.init) }
            .filter { $0.first == kind }
    }

    private func bytes(_ hex: String) -> Data {
        var data = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            data.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return data
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    func testGoldenCommands() throws {
        let lines = try goldenLines("command")
        XCTAssertEqual(lines.count, 4)
        for f in lines {
            let command = PicoCommandV1(traceID: UInt64(f[2], radix: 16)!, command: UInt8(f[3])!, value: UInt8(f[4])!)
            XCTAssertEqual(hex(command.encoded()), f[5], "Swift encode \(f)")
            XCTAssertEqual(try PicoCommandV1(from: BlazeBinaryDecoder(data: bytes(f[5]))), command, "Swift decode \(f)")
        }
    }

    func testGoldenFrames() throws {
        let lines = try goldenLines("frame")
        XCTAssertEqual(lines.count, 3)
        for f in lines {
            let packetNumber = UInt32(f[1])!
            let command = PicoCommandV1(traceID: UInt64(f[2], radix: 16)!, command: UInt8(f[3])!, value: UInt8(f[4])!)

            // Swift encode == golden (== C encode, checked by the C tests)
            let frame = PicoWire.serialFrame(PicoWire.commandPacket(packetNumber: packetNumber, command: command))
            XCTAssertEqual(hex(frame), f[6], "Swift encode \(f)")

            // golden (C-encoded) -> Swift decode
            let decoded = try PicoWire.decodeCommandFrame(bytes(f[6]))
            XCTAssertEqual(decoded.command, command)
            XCTAssertEqual(decoded.sequence, packetNumber)
            XCTAssertEqual(decoded.header.packetNumber, packetNumber)
        }
    }

    /// The reference example from the spec, spelled out by layer.
    func testReferenceFrameLayers() {
        let command = PicoCommandV1(traceID: 0x0123_4567_89AB_CDEF, command: 3, value: 0x5A)
        let frame = PicoWire.serialFrame(PicoWire.commandPacket(packetNumber: 1, command: command))
        XCTAssertEqual(hex(frame.prefix(4)), "424c415a")                                // BLAZ
        XCTAssertEqual(hex(frame.subdata(in: 4..<20)), "01000000000100000001000000010010") // header
        XCTAssertEqual(hex(frame.subdata(in: 20..<25)), "0000000001")                    // DATA type + sequence
        XCTAssertEqual(hex(frame.subdata(in: 25..<36)), "010123456789abcdef035a")        // PicoCommandV1
        XCTAssertEqual(hex(frame.suffix(4)), "4427e15a")                                 // CRC-32
    }

    func testCRC32CheckValue() {
        XCTAssertEqual(PicoWire.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    /// PacketEncoder is a local copy of BlazeTransport's PacketParser.encode. These
    /// bytes were produced by BlazeTransport's own PacketParser.encode (connection
    /// 1234, packet 1, stream 1, 13-byte payload), so the copy must match them.
    func testPacketEncoderMatchesBlazeTransport() {
        let header = BlazePacketHeader(version: 1, flags: 0, connectionID: 1234, packetNumber: 1,
                                       streamID: 1, payloadLength: 13)
        let encoded = PacketEncoder.encode(BlazePacket(header: header, payload: Data(count: 13)))
        XCTAssertEqual(hex(encoded.prefix(16)), "01000000" + "04d2" + "00000001" + "00000001" + "000d")
    }

    func testBatchIsOneFramePerCommandSameTrace() throws {
        let trace: UInt64 = 42
        let commands: [(CommandID, UInt8)] = [(.red, 1), (.green, 0), (.servoSet, 90)]
        var stream = Data()
        for (i, (cmd, value)) in commands.enumerated() {
            let packet = PicoWire.commandPacket(packetNumber: UInt32(10 + i),
                                                command: PicoCommandV1(traceID: trace, command: cmd, value: value))
            stream.append(PicoWire.serialFrame(packet))
        }
        XCTAssertEqual(stream.count, 3 * 40)
        for i in 0..<3 {
            let decoded = try PicoWire.decodeCommandFrame(stream.subdata(in: (i * 40)..<((i + 1) * 40)))
            XCTAssertEqual(decoded.command.traceID, trace)
            XCTAssertEqual(decoded.command.command, commands[i].0.rawValue)
            XCTAssertEqual(decoded.command.value, commands[i].1)
        }
    }

    func testDecodeRejectsCorruptionAndUnknownVersion() throws {
        let good = PicoWire.serialFrame(PicoWire.commandPacket(
            packetNumber: 1, command: PicoCommandV1(traceID: 7, command: .red, value: 1)))

        var flipped = good
        flipped[30] ^= 0x01
        XCTAssertThrowsError(try PicoWire.decodeCommandFrame(flipped)) {
            XCTAssertEqual($0 as? PicoWireError, .badCRC)
        }

        XCTAssertThrowsError(try PicoCommandV1(from: BlazeBinaryDecoder(data: Data([2] + [UInt8](repeating: 0, count: 10))))) {
            XCTAssertEqual($0 as? PicoWireError, .unsupportedVersion(2))
        }
    }
}
