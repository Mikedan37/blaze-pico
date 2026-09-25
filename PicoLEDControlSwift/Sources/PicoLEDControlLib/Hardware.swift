import Foundation

/// Top-level entry point for hardware device discovery and access.
///
/// `Hardware` is a namespace (enum with no cases) that provides static methods
/// to discover and connect to Pico devices. It wraps `DeviceManager` so callers
/// never need to touch the transport layer directly.
///
/// Single device:
///
///     let board = try await Hardware.first()
///     try await board.pin(5).setHigh()
///
/// Multi-device (future):
///
///     let boards = try await Hardware.devices()
///     for board in boards {
///         try await board.pin(0).setHigh()
///     }
///
public enum Hardware {

    /// Get the first (primary) connected device.
    ///
    /// Initializes the persistent session if needed. Throws if no device is found.
    public static func first() async throws -> HardwareDevice {
        let manager = DeviceManager.shared
        try await manager.warmStart()

        guard let portPath = await manager.getPrimaryPortPath() else {
            throw HardwareError.noDeviceFound
        }

        return HardwareDevice(id: portPath, portPath: portPath, manager: manager)
    }

    /// Discover all connected Pico devices.
    ///
    /// Returns one `HardwareDevice` per detected USB serial port.
    public static func devices() async throws -> [HardwareDevice] {
        let manager = DeviceManager.shared
        try await manager.warmStart()

        let ports = await manager.findPicoPorts()
        return ports.map { port in
            HardwareDevice(id: port, portPath: port, manager: manager)
        }
    }

    /// Initialize the hardware subsystem without returning a device.
    ///
    /// Call this once at daemon startup to open the persistent serial session.
    /// Equivalent to `DeviceManagerCommandHelper.initialize()`.
    public static func initialize() async throws {
        try await DeviceManager.shared.warmStart()
    }
}
