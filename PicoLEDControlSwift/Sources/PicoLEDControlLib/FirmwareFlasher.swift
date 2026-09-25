import Foundation

/// Orchestrates the full firmware flash lifecycle:
///   1. Send ENTER_BOOTLOADER via binary protocol
///   2. Wait for RP2 UF2 boot volume to mount
///   3. Copy UF2 file to the volume
///   4. Wait for device reboot (volume disappears)
///   5. Wait for serial port to reappear
///   6. Reconnect DeviceManager session
///   7. Wait for SESSION -> STATE -> BLAZE_READY
public final class FirmwareFlasher: @unchecked Sendable {
    
    public enum FlashEvent: Sendable {
        case bootloaderEnterSent
        case bootVolumeDetected(path: String)
        case uf2CopyStarted
        case uf2CopyComplete
        case deviceRebootDetected
        case waitingForSerial
        case sessionReconnected
        case readyConfirmed
        case error(String)
    }
    
    public enum FlashError: Error, LocalizedError {
        case noDeviceConnected
        case bootloaderEntryFailed(String)
        case volumeTimeout
        case uf2FileNotFound(String)
        case uf2CopyFailed(String)
        case rebootTimeout
        case serialPortTimeout
        case reconnectFailed(String)
        case readyTimeout
        
        public var errorDescription: String? {
            switch self {
            case .noDeviceConnected: return "No Pico device connected"
            case .bootloaderEntryFailed(let msg): return "Bootloader entry failed: \(msg)"
            case .volumeTimeout: return "Bootloader volume did not mount within 15 seconds"
            case .uf2FileNotFound(let path): return "UF2 file not found: \(path)"
            case .uf2CopyFailed(let msg): return "UF2 copy failed: \(msg)"
            case .rebootTimeout: return "Device did not reboot after UF2 copy (volume still mounted after 15s)"
            case .serialPortTimeout: return "Serial port did not reappear within 15 seconds after flash"
            case .reconnectFailed(let msg): return "Session reconnect failed: \(msg)"
            case .readyTimeout: return "Device did not send BLAZE_READY within 10 seconds"
            }
        }
    }
    
    private let onEvent: (FlashEvent) -> Void
    
    public init(onEvent: @escaping (FlashEvent) -> Void = { _ in }) {
        self.onEvent = onEvent
    }
    
    // MARK: - Public API
    
    /// Enter bootloader only (no flash). Returns when device is in USB bootloader mode.
    public func enterBootloader() async throws {
        try await sendBootloaderCommand()
        await DeviceManager.shared.releaseSessionForFlash()
    }
    
    /// Full flash workflow: bootloader -> copy UF2 -> reconnect -> READY
    public func flash(uf2Path: String) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: uf2Path) else {
            throw FlashError.uf2FileNotFound(uf2Path)
        }
        
        try await sendBootloaderCommand()
        await DeviceManager.shared.releaseSessionForFlash()
        
        let volumePath = try await waitForBootVolume(timeoutSeconds: 15)
        onEvent(.bootVolumeDetected(path: volumePath))
        
        try copyUF2(from: uf2Path, to: volumePath)
        
        try await waitForVolumeDisappear(volumePath: volumePath, timeoutSeconds: 15)
        onEvent(.deviceRebootDetected)
        
        onEvent(.waitingForSerial)
        try await waitForSerialPort(timeoutSeconds: 15)
        
        try await reconnectSession()
        onEvent(.sessionReconnected)
        
        try await waitForReady(timeoutSeconds: 10)
        onEvent(.readyConfirmed)
    }
    
    // MARK: - Step 1: Enter bootloader
    
    private func sendBootloaderCommand() async throws {
        await DeviceManager.shared.setBootloaderTransition(true)
        
        do {
            let success = try await DeviceManagerCommandHelper.enterBootloader()
            onEvent(.bootloaderEnterSent)
            if !success {
                print("[FirmwareFlasher] Bootloader ACK not received, but device may have rebooted")
                fflush(stdout)
            }
        } catch {
            let msg = "\(error)"
            // Disconnect errors during bootloader entry are expected
            if msg.contains("disconnected") || msg.contains("closed") || msg.contains("broken") ||
               msg.contains("not ready") || msg.contains("not initialized") {
                onEvent(.bootloaderEnterSent)
            } else {
                await DeviceManager.shared.setBootloaderTransition(false)
                throw FlashError.bootloaderEntryFailed(msg)
            }
        }
        
        // Brief delay for CDC teardown
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    
    // MARK: - Step 2: Wait for UF2 boot volume
    
    private func waitForBootVolume(timeoutSeconds: Int) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        
        while Date() < deadline {
            if let path = findBootVolume() {
                return path
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms poll
        }
        
        throw FlashError.volumeTimeout
    }
    
    /// Scan /Volumes for RP2040/RP2350 bootloader volumes containing INFO_UF2.TXT
    private func findBootVolume() -> String? {
        let fm = FileManager.default
        guard let volumes = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return nil }
        
        let candidates = ["RP2350", "RPI-RP2", "RP2"]
        
        for volume in volumes {
            let volumePath = "/Volumes/\(volume)"
            
            // Check known bootloader volume names
            for candidate in candidates {
                if volume == candidate {
                    let marker = "\(volumePath)/INFO_UF2.TXT"
                    if fm.fileExists(atPath: marker) {
                        return volumePath
                    }
                }
            }
            
            // Also check any RP* volume with INFO_UF2.TXT
            if volume.hasPrefix("RP") {
                let marker = "\(volumePath)/INFO_UF2.TXT"
                if fm.fileExists(atPath: marker) {
                    return volumePath
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Step 3: Copy UF2
    
    private func copyUF2(from sourcePath: String, to volumePath: String) throws {
        onEvent(.uf2CopyStarted)
        
        let fm = FileManager.default
        let fileName = (sourcePath as NSString).lastPathComponent
        let destPath = "\(volumePath)/\(fileName)"
        
        // Remove existing file if present
        if fm.fileExists(atPath: destPath) {
            try? fm.removeItem(atPath: destPath)
        }
        
        do {
            try fm.copyItem(atPath: sourcePath, toPath: destPath)
        } catch {
            throw FlashError.uf2CopyFailed("\(error)")
        }
        
        // Sync to flush filesystem buffers
        let syncProcess = Process()
        syncProcess.executableURL = URL(fileURLWithPath: "/bin/sync")
        try? syncProcess.run()
        syncProcess.waitUntilExit()
        
        onEvent(.uf2CopyComplete)
    }
    
    // MARK: - Step 4: Wait for volume to disappear (device reboot)
    
    private func waitForVolumeDisappear(volumePath: String, timeoutSeconds: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        let fm = FileManager.default
        
        while Date() < deadline {
            if !fm.fileExists(atPath: volumePath) {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms poll
        }
        
        throw FlashError.rebootTimeout
    }
    
    // MARK: - Step 5: Wait for serial port
    
    private func waitForSerialPort(timeoutSeconds: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        
        while Date() < deadline {
            if findPicoSerialPort() != nil {
                // Brief delay for CDC enumeration to stabilize
                try? await Task.sleep(nanoseconds: 500_000_000)
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms poll
        }
        
        throw FlashError.serialPortTimeout
    }
    
    private func findPicoSerialPort() -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: "/dev") else { return nil }
        return files
            .filter { $0.hasPrefix("cu.usbmodem") }
            .map { "/dev/\($0)" }
            .sorted()
            .first
    }
    
    // MARK: - Step 6: Reconnect session
    
    private func reconnectSession() async throws {
        // Clear bootloader transition flag, invalidate port cache, reconnect
        await DeviceManager.shared.setBootloaderTransition(false)
        await DeviceManager.shared.invalidatePortCache()
        
        do {
            try await DeviceManager.shared.warmStart()
        } catch {
            throw FlashError.reconnectFailed("\(error)")
        }
    }
    
    // MARK: - Step 7: Wait for BLAZE_READY
    
    private func waitForReady(timeoutSeconds: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        
        while Date() < deadline {
            do {
                let session = try await DeviceManager.shared.getSession()
                if session.isReady {
                    return
                }
            } catch {
                // Session not ready yet — keep polling
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms poll
        }
        
        throw FlashError.readyTimeout
    }
}
