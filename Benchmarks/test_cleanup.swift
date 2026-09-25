import Foundation
import PicoLEDControlLib

@main
struct TestCleanup {
    static func main() async {
        guard let devicePort = findPicoDevice() else {
            print("❌ No device")
            exit(1)
        }
        
        let session = PicoSession(portPath: devicePort, deviceID: "test")
        try? await session.connect(timeoutMs: 5000)
        
        // Wait for ready
        var waitCount = 0
        while !session.isReady && waitCount < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitCount += 1
        }
        
        print("🧹 Testing cleanup: Turning all LEDs OFF...")
        for i in 1...3 {
            do {
                let (success, _) = try await session.sendCommandWithCompletion(
                    commandID: .all,
                    value: 0,
                    ackTimeoutMs: 1000,
                    stateTimeoutMs: 2000
                )
                print("   Attempt \(i): \(success ? "✅ Success" : "❌ Failed")")
                try? await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                print("   Attempt \(i): Error - \(error)")
            }
        }
        print("✅ Cleanup test complete")
    }
    
    static func findPicoDevice() -> String? {
        let fileManager = FileManager.default
        guard let devices = try? fileManager.contentsOfDirectory(atPath: "/dev") else { return nil }
        return devices.filter { $0.hasPrefix("tty.usbmodem") }.sorted().last.map { "/dev/\($0)" }
    }
}
