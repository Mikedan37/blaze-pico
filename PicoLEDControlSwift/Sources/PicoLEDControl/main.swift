import Foundation
import ArgumentParser
import PicoLEDControlLib

@main
struct PicoLEDControl: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "pico-led-control",
        abstract: "Control Blaze Pico LEDs via BlazeTransport protocol",
        discussion: """
        Sends LED control commands to a Raspberry Pi Pico using the BlazeTransport protocol.
        
        Supports both binary protocol (fast, agent-friendly) and text commands (backward compatible).
        
        All arguments are joined into a single command. For example:
          "RED ON" sends the command "RED ON" (not "RED" then "ON")
        
        Examples:
          pico-led-control RED ON
          pico-led-control ALL OFF
          pico-led-control GREEN ON
          pico-led-control --port /dev/cu.usbmodem1103 RED OFF
          pico-led-control --query-state
        """
    )
    
    @Argument(help: "LED command to send (e.g., 'RED ON', 'ALL OFF'). Multiple words are joined into one command.")
    var commandParts: [String] = []
    
    @Option(name: .shortAndLong, help: "Serial port path (default: auto-detect)")
    var port: String?
    
    @Option(name: .shortAndLong, help: "Baud rate (default: 115200)")
    var baud: Int = 115200
    
    @Flag(name: .long, help: "Query LED state from Pico")
    var queryState: Bool = false
    
    @Flag(name: .long, help: "Print comprehensive telemetry metrics report")
    var metrics: Bool = false
    
    @Flag(name: .long, help: "Simulate full pipeline with all stages (for testing)")
    var fullPipeline: Bool = false
    
    @Flag(name: .long, help: "Test all colors from the color table (sequences through each for 2s)")
    var testColors: Bool = false
    
    func run() async throws {
        // Auto-detect port if not specified
        let portPath = port ?? autoDetectPort() ?? "/dev/cu.usbmodem1101"
        
        if port == nil {
            print("Using port: \(portPath)")
        }
        
        let controller = PicoLEDController(portPath: portPath)
        defer { controller.close() }
        
        // Handle color test sequence
        if testColors {
            try runColorTest(controller: controller)
            return
        }
        
        // Handle full pipeline simulation
        if fullPipeline && !commandParts.isEmpty {
            let fullCommand = commandParts.joined(separator: " ").uppercased()
            let color = commandParts[0].uppercased()
            
            print("🎤 Stage 1: Voice Detected")
            controller.markVoiceDetected()
            usleep(50_000) // 50ms
            
            print("🤖 Stage 2: LLM Start")
            controller.markLLMStart()
            usleep(200_000) // 200ms
            
            print("✅ Stage 3: LLM Done")
            controller.markLLMDone(
                voicePhrase: "turn on the \(color.lowercased()) light",
                llmCommand: fullCommand
            )
            usleep(10_000) // 10ms
            
            print("🚀 Stage 4: Agent Dispatch")
            controller.markAgentDispatch()
            usleep(5_000) // 5ms
            
            print("📡 Stage 5: Executing Command")
            let success = try controller.sendCommand(fullCommand)
            
            if success {
                print("✅ Full pipeline completed successfully")
            } else {
                print("❌ Pipeline completed but command failed")
            }
            
            if metrics {
                controller.printMetricsReport()
            }
            
            return
        }
        
        // Handle state query
        if queryState {
            print("Querying LED state...")
            if let states = try controller.queryState() {
                print("LED States:")
                print("  Red: \(states["R"] == true ? "ON" : "OFF")")
                print("  Green: \(states["G"] == true ? "ON" : "OFF")")
                print("  Yellow: \(states["Y"] == true ? "ON" : "OFF")")
                print("  Blue: \(states["B"] == true ? "ON" : "OFF")")
                print("  Multi: \(states["M"] == true ? "ON" : "OFF")")
            } else {
                print("⚠ Failed to query state")
            }
            return
        }
        
        // Join all arguments into a single command
        // "RED ON" becomes "RED ON" (not ["RED", "ON"])
        let fullCommand = commandParts.joined(separator: " ").uppercased()
        
        guard !fullCommand.isEmpty else {
            print(PicoLEDControl.helpMessage())
            return
        }
        
        // DEBUG: Show exactly what we're sending
        // This should be ONE command like "RED ON", not multiple
        print("Sending command: \"\(fullCommand)\"", terminator: "")
        
        let ackReceived = try controller.sendCommand(fullCommand)
        
        // Allow USB CDC buffer to flush before process exit
        usleep(100_000)
        
        if ackReceived {
            print(" ✓ (ACK received)")
            print("✓ Command sent and acknowledged")
        } else {
            print(" ⚠ (no ACK - check serial output)")
            print("⚠ Command sent but no ACK received")
            controller.recordFailure(command: fullCommand, error: "No ACK received")
        }
        
        // Print metrics report if requested
        if metrics {
            controller.printMetricsReport()
        }
    }
    
    /// Auto-detect Pico USB serial port
    /// Searches /dev/cu.usbmodem* (macOS renumbers these on replug)
    private func autoDetectPort() -> String? {
        let fileManager = FileManager.default
        let devPath = "/dev"
        
        guard let entries = try? fileManager.contentsOfDirectory(atPath: devPath) else {
            return nil
        }
        
        // Look for ALL usbmodem devices (macOS renumbers: 1101, 1103, 14201, etc.)
        let usbPorts = entries.filter { $0.hasPrefix("cu.usbmodem") }
            .sorted()
        
        // Return first found (most recently plugged in is usually first)
        // Future: could check which one responds to ping
        return usbPorts.first.map { "/dev/\($0)" }
    }
    
    // MARK: - Color Test
    
    private static let colorTable: [(name: String, r: Int, g: Int, b: Int)] = [
        ("red",         100,   0,   0),
        ("green",         0, 100,   0),
        ("blue",          0,   0, 100),
        ("yellow",      100, 100,   0),
        ("orange",       80,  30,   0),
        ("purple",       60,   0,  60),
        ("violet",       50,   0,  80),
        ("cyan",          0, 100, 100),
        ("teal",          0,  60,  60),
        ("pink",        100,  20,  40),
        ("magenta",     100,   0, 100),
        ("white",       100, 100, 100),
        ("warm white",  100,  60,  30),
        ("coral",       100,  40,  30),
        ("indigo",       20,   0,  60),
        ("lavender",     60,  40,  80),
        ("lime",         50, 100,   0),
        ("gold",        100,  70,   0),
        ("amber",       100,  50,   0),
        ("sunset",      100,  40,  10),
        ("sky blue",     30,  60, 100),
        ("navy",          0,   0,  50),
        ("mint",         20, 100,  50),
        ("emerald",      10,  80,  30),
        ("dim red@30",   30,   0,   0),
    ]
    
    private func runColorTest(controller: PicoLEDController) throws {
        let total = Self.colorTable.count
        var passed = 0
        var failed: [(name: String, error: String)] = []
        
        print("Color Pipeline Test")
        print("===================")
        print("Testing \(total) colors via PicoLEDController.sendBinaryCommand()")
        print("Each color holds for 2 seconds\n")
        
        // Clear first
        let clearOk = try setRGB(controller: controller, r: 0, g: 0, b: 0)
        if !clearOk {
            print("WARN: Initial clear did not get full ACK\n")
        }
        usleep(500_000)
        
        for (index, color) in Self.colorTable.enumerated() {
            let label = "[\(index + 1)/\(total)]"
            print("\(label) \(color.name) -> R=\(color.r) G=\(color.g) B=\(color.b) ", terminator: "")
            
            do {
                let ok = try setRGB(controller: controller, r: color.r, g: color.g, b: color.b)
                if ok {
                    print("ACK")
                    passed += 1
                } else {
                    print("NO ACK")
                    failed.append((color.name, "No ACK from firmware"))
                }
            } catch {
                print("ERROR: \(error.localizedDescription)")
                failed.append((color.name, error.localizedDescription))
            }
            
            usleep(2_000_000)
        }
        
        // Clear at end
        _ = try? setRGB(controller: controller, r: 0, g: 0, b: 0)
        usleep(100_000)
        
        // Summary
        print("\n===================")
        print("Results: \(passed)/\(total) passed")
        if !failed.isEmpty {
            print("\nFailed:")
            for f in failed {
                print("  - \(f.name): \(f.error)")
            }
        }
        if passed == total {
            print("\nAll colors validated.")
        }
    }
    
    private func setRGB(controller: PicoLEDController, r: Int, g: Int, b: Int) throws -> Bool {
        let r_ok = try controller.sendBinaryCommand(commandID: .multiRed, value: UInt8(r))
        usleep(30_000)
        let g_ok = try controller.sendBinaryCommand(commandID: .multiGreen, value: UInt8(g))
        usleep(30_000)
        let b_ok = try controller.sendBinaryCommand(commandID: .multiBlue, value: UInt8(b))
        usleep(30_000)
        return r_ok && g_ok && b_ok
    }
}
