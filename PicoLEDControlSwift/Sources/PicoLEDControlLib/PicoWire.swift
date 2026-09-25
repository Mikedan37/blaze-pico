import Foundation
import BlazeBinary

/// Mac -> Pico command message, serialized with BlazeBinary.
///
/// Mirrors `firmware/protocol/pico_command.h`. Fields in order:
/// `version UInt8 (= 1)`, `traceID UInt64`, `command UInt8`, `value UInt8`.
/// Golden bytes for traceID 0x0123456789ABCDEF, command 3, value 0x5A:
/// `01 01 23 45 67 89 AB CD EF 03 5A`.
public struct PicoCommandV1: BlazeBinaryCodable, Equatable {
    public static let version: UInt8 = 1

    public let traceID: UInt64
    public let command: UInt8
    public let value: UInt8

    public init(traceID: UInt64, command: UInt8, value: UInt8) {
        self.traceID = traceID
        self.command = command
        self.value = value
    }

    public init(traceID: UInt64, command: CommandID, value: UInt8) {
        self.init(traceID: traceID, command: command.rawValue, value: value)
    }

    public func blazeEncode(to encoder: BlazeBinaryEncoder) {
        encoder.encode(Self.version)
        encoder.encode(traceID)
        encoder.encode(command)
        encoder.encode(value)
    }

    public init(from decoder: BlazeBinaryDecoder) throws {
        let version = try decoder.decodeUInt8()
        guard version == Self.version else { throw PicoWireError.unsupportedVersion(version) }
        traceID = try decoder.decodeUInt64()
        command = try decoder.decodeUInt8()
        value = try decoder.decodeUInt8()
    }

    /// BlazeBinary bytes of this command (11 bytes).
    public func encoded() -> Data {
        let encoder = BlazeBinaryEncoder()
        blazeEncode(to: encoder)
        return encoder.encodedData()
    }
}

/// Firmware wire-protocol compatibility, established per device session.
///
/// Firmware reports `PROTOCOL=<n>` in its text `DEVICE_INFO` reply. This host
/// speaks exactly protocol 2 (BlazeBinary PicoCommandV1 frames with CRC-32).
/// Protocol 1 firmware reads a protocol 2 frame as a hand-packed batch and can
/// execute trace-ID bytes as commands, so no binary byte is written until the
/// current session has reported protocol 2.
public enum ProtocolCompatibility: Equatable {
    /// Not yet checked for this session. Binary commands are blocked.
    case unknown
    case compatible(Int)
    /// Device reported another version. 0 means missing or malformed.
    case incompatible(reported: Int)

    public static let requiredVersion = 2

    public var isCompatible: Bool {
        if case .compatible = self { return true }
        return false
    }

    /// Decide from the firmware's reported protocol (0 = missing or malformed).
    public static func evaluate(reportedVersion: Int) -> ProtocolCompatibility {
        reportedVersion == requiredVersion ? .compatible(reportedVersion) : .incompatible(reported: reportedVersion)
    }
}

public enum PicoProtocolError: Error, LocalizedError, Equatable {
    case incompatibleFirmware(reported: Int)
    case protocolUnknown

    public var errorDescription: String? {
        switch self {
        case .incompatibleFirmware(let reported):
            let found = reported == 0 ? "no valid protocol version" : "protocol \(reported)"
            return "Incompatible Pico firmware protocol (device reports \(found)). "
                + "Host requires protocol \(ProtocolCompatibility.requiredVersion). Reflash the device firmware."
        case .protocolUnknown:
            return "Pico firmware protocol not confirmed for this session (no DEVICE_INFO reply). "
                + "Host requires protocol \(ProtocolCompatibility.requiredVersion). Commands are blocked."
        }
    }
}

public enum PicoWireError: Error, Equatable {
    case unsupportedVersion(UInt8)
    case badMagic
    case truncated
    case badHeaderVersion(UInt8)
    case badCRC
    case notDataFrame(UInt8)
    case trailingBytes
}

/// The USB serial envelope around a BlazeTransport packet:
///
///     "BLAZ" | 16-byte BlazeTransport header | DATA frame | CRC-32
///
/// DATA frame = `[frameType 0][sequence UInt32 BE][PicoCommandV1]`, as in
/// BlazeTransport's `ConnectionManager.buildDataFramePayload`. The CRC-32 is
/// zlib/IEEE 802.3, big-endian, over header + payload. Mirrors
/// `firmware/protocol/blaze_serial.h`.
public enum PicoWire {
    public static let magic = Data("BLAZ".utf8)
    public static let headerSize = 16

    /// BlazeTransport DATA frame carrying one command.
    public static func dataPayload(sequence: UInt32, command: PicoCommandV1) -> Data {
        var payload = Data([0x00])
        payload.append(contentsOf: withUnsafeBytes(of: sequence.bigEndian) { Data($0) })
        payload.append(command.encoded())
        return payload
    }

    /// The BlazeTransport packet for one command. The DATA frame sequence equals the packet number.
    public static func commandPacket(packetNumber: UInt32, command: PicoCommandV1) -> BlazePacket {
        let payload = dataPayload(sequence: packetNumber, command: command)
        let header = BlazePacketHeader(
            version: 1,
            flags: 0,
            connectionID: 1,
            packetNumber: packetNumber,
            streamID: 1,
            payloadLength: UInt16(payload.count)
        )
        return BlazePacket(header: header, payload: payload)
    }

    /// Complete bytes to write to the serial port for one packet.
    public static func serialFrame(_ packet: BlazePacket) -> Data {
        let covered = PacketEncoder.encode(packet)
        var frame = magic
        frame.append(covered)
        frame.append(contentsOf: withUnsafeBytes(of: crc32(covered).bigEndian) { Data($0) })
        return frame
    }

    /// CRC-32 (IEEE 802.3, same as zlib crc32). Check value: "123456789" -> 0xCBF43926.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Decode one complete serial frame. The host never receives these; this
    /// exists so tests can prove C-encoded frames decode in Swift.
    public static func decodeCommandFrame(_ frame: Data) throws
        -> (header: BlazePacketHeader, sequence: UInt32, command: PicoCommandV1) {
        let bytes = [UInt8](frame)
        guard bytes.count >= 4 + headerSize else { throw PicoWireError.truncated }
        guard Data(bytes[0..<4]) == magic else { throw PicoWireError.badMagic }

        func be32(_ i: Int) -> UInt32 { bytes[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        let header = BlazePacketHeader(
            version: bytes[4],
            flags: bytes[5],
            connectionID: be32(6),
            packetNumber: be32(10),
            streamID: be32(14),
            payloadLength: UInt16(bytes[18]) << 8 | UInt16(bytes[19])
        )
        guard header.version == 1 else { throw PicoWireError.badHeaderVersion(header.version) }

        let payloadEnd = 4 + headerSize + Int(header.payloadLength)
        guard bytes.count >= payloadEnd + 4 else { throw PicoWireError.truncated }
        guard bytes.count == payloadEnd + 4 else { throw PicoWireError.trailingBytes }
        guard be32(payloadEnd) == crc32(Data(bytes[4..<payloadEnd])) else { throw PicoWireError.badCRC }

        let payload = bytes[(4 + headerSize)..<payloadEnd]
        guard payload.count >= 5 else { throw PicoWireError.truncated }
        guard payload.first == 0 else { throw PicoWireError.notDataFrame(payload.first!) }

        let decoder = BlazeBinaryDecoder(data: Data(payload.dropFirst(5)))
        let command = try PicoCommandV1(from: decoder)
        guard decoder.remainingData.isEmpty else { throw PicoWireError.trailingBytes }
        return (header, be32(4 + headerSize + 1), command)
    }
}
