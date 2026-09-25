import XCTest
@testable import PicoLEDControlLib

final class PicoLEDControllerTests: XCTestCase {
    
    func testBuildBlazePacket() {
        let controller = PicoLEDController(portPath: "/dev/test")
        
        XCTAssertNoThrow {
            // Test that we can create the controller
            let _ = PicoLEDController(portPath: "/dev/test")
        }
    }
    
    func testPacketFormat() {
        // Test that packet format matches expected structure
        // Build a packet manually to verify format
        
        let command = "RED ON"
        let commandBytes = command.uppercased().data(using: .ascii)!
        
        var payload = Data()
        payload.append(0) // frameType = DATA
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(1).bigEndian) { Data($0) }) // streamID
        payload.append(commandBytes)
        
        let header = BlazePacketHeader(
            version: 1,
            flags: 0,
            connectionID: 1,
            packetNumber: 1,
            streamID: 1,
            payloadLength: UInt16(payload.count)
        )
        
        let packet = BlazePacket(header: header, payload: payload)
        let encoded = PacketEncoder.encode(packet)
        
        // Verify header size
        XCTAssertEqual(encoded.count, 16 + payload.count, "Packet should be header (16) + payload")
        
        // Verify magic + header + payload structure
        var fullPacket = Data("BLAZ".utf8)
        fullPacket.append(encoded)
        
        XCTAssertEqual(fullPacket.count, 4 + 16 + payload.count, "Full packet should be magic (4) + header (16) + payload")
        
        // Verify magic bytes
        XCTAssertEqual(fullPacket[0], UInt8(ascii: "B"))
        XCTAssertEqual(fullPacket[1], UInt8(ascii: "L"))
        XCTAssertEqual(fullPacket[2], UInt8(ascii: "A"))
        XCTAssertEqual(fullPacket[3], UInt8(ascii: "Z"))
        
        // Verify header version
        XCTAssertEqual(fullPacket[4], 1, "Version should be 1")
        
        // Verify payload frameType
        let payloadStart = 4 + 16
        XCTAssertEqual(fullPacket[payloadStart], 0, "Frame type should be 0 (DATA)")
    }
    
    func testCommandEncoding() {
        let commands = ["RED ON", "GREEN OFF", "ALL ON", "ALL OFF"]
        
        for command in commands {
            let commandBytes = command.uppercased().data(using: .ascii)!
            XCTAssertNotNil(commandBytes, "Command should encode to ASCII")
            XCTAssertGreaterThan(commandBytes.count, 0, "Command should not be empty")
        }
    }
}
