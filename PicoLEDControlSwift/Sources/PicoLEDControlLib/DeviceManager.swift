import Foundation
import Combine

/// Central device manager for all Pico devices
/// PERMANENT SERIAL SESSION ARCHITECTURE: Maintains persistent sessions, handles reconnects, routes commands
/// RULE 1: Serial must be permanently open - no per-command port scanning or session reopening
public actor DeviceManager {
    public static let shared = DeviceManager()
    
    // PERMANENT SERIAL SESSION: Single persistent session for primary Pico device
    // This eliminates cold-path reopening costs (200-500ms per command)
    private var persistentSession: PicoSession?
    private var persistentPort: String?
    private var persistentDeviceID: String?
    
    // Active device sessions (for multi-device support, but primary uses persistentSession)
    private var sessions: [String: PicoSession] = [:]
    
    // Port path mapping (deviceID -> portPath for state sync)
    private var portPaths: [String: String] = [:]
    
    // Device registry
    private var deviceRegistry: [String: DeviceInfo] = [:]
    
    // Event aggregator (all device events)
    // Note: Must be nonisolated for Combine PassthroughSubject
    nonisolated public let allEvents = PassthroughSubject<(deviceID: String, event: PicoEventType), Never>()
    
    // KEEPALIVE PING: Background task to keep USB serial warm (RULE 2)
    private var keepaliveTask: Task<Void, Never>?
    
    // DEVICE MONITOR: Background task that watches /dev/ for Pico appearance.
    // Runs for process lifetime. Zero overhead when connected (nil-check per cycle).
    // When disconnected, polls every 2s and auto-connects on detection.
    private var deviceMonitorTask: Task<Void, Never>?
    
    // CACHED PORT SCAN: Port scan result cached (RULE 3)
    private var cachedPorts: [String]?
    private var portScanTimestamp: Date?
    private let portCacheValiditySeconds: TimeInterval = 60  // Cache ports for 60 seconds
    
    // Recovery flag to serialize hard failure handling (actor isolation prevents races)
    private var isRecovering: Bool = false
    
    // CRITICAL FIX: Prevent concurrent warmStart() calls (actor isolation isn't enough for async operations)
    private var isWarmStarting: Bool = false
    
    // Bootloader transition flag: suppresses reconnect retries and error logging
    // Set before sending ENTER_BOOTLOADER, cleared after flash + reconnect
    private var _isBootloaderTransition: Bool = false
    
    // Disconnect callback for external state invalidation (e.g. DeviceStateManager)
    private var _onDisconnect: (() -> Void)?
    
    private init() {
        // Note: Cannot call async methods from init, so warmStart() must be called explicitly
        // CRITICAL DIAGNOSTIC: Log object identity to detect multiple instances
        print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] DeviceManager INIT - id=\(ObjectIdentifier(self))")
        fflush(stdout)
    }
    
    /// Background device monitor — polls /dev/ for Pico appearance when disconnected.
    /// When connected (`persistentPort != nil`), each cycle is just a nil-check (zero cost).
    /// When disconnected, scans /dev/ every 2s and calls warmStart() on detection.
    /// Started once (idempotent) and runs for process lifetime.
    private func ensureDeviceMonitor() {
        guard deviceMonitorTask == nil else { return }
        
        print("[DeviceManager] [Monitor] Starting background device monitor (2s poll)")
        fflush(stdout)
        
        deviceMonitorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                
                if persistentPort != nil { continue }
                if _isBootloaderTransition { continue }
                if isWarmStarting { continue }
                
                invalidatePortCache()
                let ports = findPicoPorts()
                guard !ports.isEmpty else { continue }
                
                print("[DeviceManager] [Monitor] 🔌 Pico detected at \(ports[0]) — auto-connecting...")
                fflush(stdout)
                do {
                    try await warmStart()
                    print("[DeviceManager] [Monitor] ✅ Auto-connected to Pico")
                    fflush(stdout)
                } catch {
                    print("[DeviceManager] [Monitor] Connection failed: \(error.localizedDescription)")
                    fflush(stdout)
                }
            }
        }
    }
    
    /// WARM START: Initialize persistent serial session on daemon startup (RULE 1)
    /// Scans ports ONCE, opens session immediately, stores permanently
    /// This eliminates cold-path reopening costs
    public func warmStart() async throws {
        ensureDeviceMonitor()
        // CRITICAL FIX: If persistent session already exists and is ready, don't recreate it
        if let existingSession = persistentSession, existingSession.isConnected && existingSession.isReady {
            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] warmStart() called but persistent session already exists and is ready - skipping")
            fflush(stdout)
            return
        }
        
        // CRITICAL FIX: Prevent concurrent warmStart() calls
        if isWarmStarting {
            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] warmStart() already in progress - waiting...")
            fflush(stdout)
            // Wait for existing warmStart to complete by checking periodically
            var waitCount = 0
            while isWarmStarting && waitCount < 50 { // Max 5 seconds wait
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                waitCount += 1
                // Check if session is now ready
                if let session = persistentSession, session.isConnected && session.isReady {
                    print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Concurrent warmStart() completed - session ready")
                    fflush(stdout)
                    return
                }
            }
            if isWarmStarting {
                print("[DeviceManager] 🔴 Concurrent warmStart() timeout - refusing to create duplicate session")
                fflush(stdout)
                throw NSError(domain: "DeviceManager", code: -3,
                             userInfo: [NSLocalizedDescriptionKey: "Concurrent warmStart() timed out - another warmStart is still in progress"])
            }
        }
        
        isWarmStarting = true
        defer { isWarmStarting = false }
        
        print("[DeviceManager] 🔥 warmStart() called - scanning for Pico devices...")
        print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Current persistentSession state: \(persistentSession != nil ? "exists" : "nil")")
        if let session = persistentSession {
            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Session state: isConnected=\(session.isConnected), isReady=\(session.isReady)")
        }
        fflush(stdout)
        
        // Scan for device with retry (USB re-enumeration can take a moment after replug)
        invalidatePortCache()
        var ports = findPicoPorts()
        if ports.isEmpty {
            print("[DeviceManager] No Pico found, retrying scan (3 attempts, 1s apart)...")
            fflush(stdout)
            for attempt in 1...3 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                invalidatePortCache()
                ports = findPicoPorts()
                if !ports.isEmpty {
                    print("[DeviceManager] Found device on retry \(attempt)")
                    fflush(stdout)
                    break
                }
            }
        }
        cachedPorts = ports
        portScanTimestamp = Date()
        
        print("[DeviceManager] Found \(ports.count) Pico port(s): \(ports)")
        fflush(stdout)
        
        guard let port = ports.first else {
            let error = NSError(domain: "DeviceManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "No Pico device found"])
            print("[DeviceManager] ❌ warmStart() failed: \(error.localizedDescription)")
            fflush(stdout)
            throw error
        }
        
        persistentPort = port
        persistentDeviceID = port
        
        print("[DeviceManager] Creating PicoSession for port: \(port)")
        fflush(stdout)
        
        // Create and connect persistent session
        let session = PicoSession(portPath: port, deviceID: port)
        
        // Cancel previous subscriptions to prevent unbounded cancellables growth on reconnect
        cancellables.removeAll()
        
        // Subscribe to events (nonisolated access to allEvents)
        let allEventsRef = allEvents
        session.events
            .sink { [weak self] event in
                Task { @MainActor in
                    allEventsRef.send((deviceID: port, event: event))
                    
                    // RULE 1: Handle hard failure - if error event indicates write/read failure, trigger handleHardFailure()
                    // CRITICAL FIX: Only trigger on ACTUAL hard failures, not soft failures
                    if case .error(let errorEvent) = event {
                        let errorMsg = errorEvent.message.lowercased()
                        
                        // CRITICAL: Only classify as "hard" if it's an actual disconnect or repeated failure
                        // Soft failures (single timeout, USB stall) should NOT trigger handleHardFailure()
                        let isHardFailure = errorMsg.contains("disconnected") || 
                                          errorMsg.contains("connection closed") ||
                                          errorMsg.contains("connection lost") ||
                                          errorMsg.contains("broken pipe") ||
                                          errorMsg.contains("serial read failed") ||
                                          errorMsg.contains("session invalidated")
                        
                        // Single write/read failures are SOFT - don't clear session
                        // Only clear on actual disconnect or session invalidation
                        if isHardFailure {
                            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Hard failure detected in event: \(errorEvent.message)")
                            fflush(stdout)
                            // Hard failure detected - clear persistent session and reconnect
                            if let manager = self {
                                await manager.handleHardFailure()
                            }
                        } else {
                            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Soft failure in event (NOT clearing session): \(errorEvent.message)")
                            fflush(stdout)
                        }
                    }
                }
            }
            .store(in: &cancellables)
        
        print("[DeviceManager] Connecting to PicoSession...")
        fflush(stdout)
        
        do {
            // Use 5s timeout to allow device boot time (USB enumeration + CDC stability + boot messages)
            try await session.connect(timeoutMs: 5000)
            
            print("[DeviceManager] ✅ PicoSession connected - isConnected=\(session.isConnected), isReady=\(session.isReady)")
            fflush(stdout)
            
            if let oldSession = persistentSession {
                print("[DeviceManager] Cleaning up stale session before replacement (isConnected=\(oldSession.isConnected))")
                fflush(stdout)
                oldSession.invalidate()
                oldSession.disconnect()
            }
            
            persistentSession = session
            sessions[port] = session
            portPaths[port] = port
            
            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] DeviceManager(id=\(ObjectIdentifier(self))) persistentSession SET - session exists: \(persistentSession != nil)")
            fflush(stdout)
            
            // RECONNECT RECOVERY: Query state on connect to establish authoritative state
            // Hardware is the authority - query state snapshot with seq
            Task.detached { [weak self] in
                do {
                    print("[DeviceManager] 🔄 Querying state on connect (reconnect recovery)...")
                    fflush(stdout)
                    // Use longer timeout for reconnect query (device may be slow to respond)
                    if let state = try await session.queryState(timeoutMs: 2000) {
                        print("[DeviceManager] ✅ Reconnect recovery: Got state snapshot: \(state)")
                        fflush(stdout)
                        // State will be applied via STATUS event (with seq) - no manual update needed
                    } else {
                        print("[DeviceManager] ⚠️ Reconnect recovery: State query timeout (will recover on first command)")
                        fflush(stdout)
                    }
                } catch {
                    print("[DeviceManager] ⚠️ Reconnect recovery: State query failed (will recover on first command): \(error)")
                    fflush(stdout)
                }
            }
            
            // Start keepalive ping (RULE 2)
            startKeepalivePing()
            
            print("[DeviceManager] ✅ Warm start complete - persistent session opened on \(port)")
            fflush(stdout)
        } catch {
            print("[DeviceManager] ❌ warmStart() failed during connect: \(error)")
            fflush(stdout)
            throw error
        }
    }
    
    /// KEEPALIVE PING: Background task to keep USB serial warm (RULE 2)
    /// Sends lightweight ping every 30 seconds to prevent USB sleep.
    /// Skips if a command is already in flight to avoid COMMAND ALREADY IN FLIGHT errors.
    private func startKeepalivePing() {
        keepaliveTask?.cancel()
        
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await ContinuousClock().sleep(until: .now + .seconds(30))
                
                guard !Task.isCancelled else { break }
                
                // Skip keepalive during bootloader transition
                if await self?._isBootloaderTransition == true { continue }
                
                if let session = await self?.persistentSession,
                   session.isConnected && session.isReady {
                    guard !session.commandInFlight else {
                        continue
                    }
                    do {
                        try await session.sendCommand(commandID: .queryState, value: 0)
                    } catch let err as NSError where err.code == -5 {
                        // Command already in flight - skip this cycle
                    } catch {
                        print("[DeviceManager] Keepalive ping failed: \(error)")
                    }
                }
            }
        }
    }
    
    /// Get persistent session (RULE 1: Reuse permanent session, never reopen)
    /// If persistent session exists and is connected, return it immediately
    /// If not, attempt warmStart() with timeout to prevent hanging
    /// NO PORT SCANNING - uses cached port from warmStart()
    /// CRITICAL FIX: Return session immediately without ANY blocking operations
    public func getSession(portPath: String? = nil, deviceID: String? = nil) async throws -> PicoSession {
        // CRITICAL DIAGNOSTIC: Log object identity to detect multiple instances
        print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] getSession() called on DeviceManager(id=\(ObjectIdentifier(self)))")
        print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] persistentSession is nil? \(persistentSession == nil)")
        if let session = persistentSession {
            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Session state: isConnected=\(session.isConnected), isReady=\(session.isReady)")
        }
        fflush(stdout)
        
        // CRITICAL FIX: Return session immediately if available - ZERO blocking
        // The periodic state sync runs in detached background task and won't block this
        // FIX: Also check isReady - session must be ready to accept commands
        if let session = persistentSession, session.isConnected && session.isReady {
            // Return immediately - no logging, no checks, no waiting
            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Returning existing persistent session (isConnected=\(session.isConnected), isReady=\(session.isReady))")
            fflush(stdout)
            return session
        }
        
        // CRITICAL FIX: If session is nil, fail fast instead of blocking on reconnect
        // Reconnect should happen asynchronously in background, not inline in request path
        if persistentSession == nil {
            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] ❌ FAIL FAST: persistentSession is nil - returning error immediately")
            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Starting async reconnect in background (non-blocking)")
            fflush(stdout)
            
            // Start reconnect asynchronously (don't await - let it happen in background)
            Task.detached(priority: .utility) { [weak self] in
                guard let self = self else { return }
                do {
                    print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Background reconnect started")
                    fflush(stdout)
                    try await self.warmStart()
                    print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Background reconnect completed")
                    fflush(stdout)
                } catch {
                    print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Background reconnect failed: \(error)")
                    fflush(stdout)
                }
            }
            
            // Return error immediately - don't block on reconnect
            throw NSError(domain: "DeviceManager", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "Device not ready - persistent session not initialized. Reconnecting in background. Please retry command in a moment."])
        }
        
        // CRITICAL FIX #4: Session exists but not ready - wait for event reader to detect readiness
        // Event reader will detect HEARTBEAT READY:1 or BLAZE_READY and set isReady=true
        // DO NOT create a new session - wait for existing one to become ready
        if let session = persistentSession, session.isConnected && !session.isReady {
            print("[DeviceManager] ⚠️ Session exists but not ready - waiting for event reader to detect readiness (max 3s)...")
            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Event reader should detect HEARTBEAT READY:1 or BLAZE_READY")
            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Event reader also detects HEARTBEAT (firmware alive) as readiness signal")
            fflush(stdout)
            
            // Wait for readiness via event reader (HEARTBEAT READY:1, HEARTBEAT, or BLAZE_READY)
            // Event reader runs in background and will set isReady=true when it sees READY signal
            let startTime = Date()
            while Date().timeIntervalSince(startTime) < 3.0 {
                if session.isReady {
                    print("[DeviceManager] ✅ Session became ready via event reader!")
                    fflush(stdout)
                    return session
                }
                // Small delay to allow event reader to process incoming serial data
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            
            print("[DeviceManager] ⚠️ Session still not ready after 3s wait - event reader may not have detected READY signal")
            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] This usually means firmware already sent BLAZE_READY before we connected")
            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Event reader should catch HEARTBEAT READY:1 or HEARTBEAT - checking serial output...")
            fflush(stdout)
            
            // CRITICAL: Don't create a new session - the existing one should become ready
            // If it doesn't, the event reader isn't working or firmware isn't sending HEARTBEAT
            throw NSError(
                domain: "DeviceManager",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Device session not ready after 3s wait. Event reader should detect HEARTBEAT READY:1, HEARTBEAT, or BLAZE_READY. Check serial output for READY signals. Session exists but readiness not detected."]
            )
        }
        
        // Session missing or disconnected - log and attempt recovery (only happens on first call or disconnect)
        // This path should be rare - most calls should hit the fast path above
        if persistentSession == nil {
            print("[DeviceManager] ⚠️ No persistent session - attempting warmStart()...")
            fflush(stdout)
        } else if let session = persistentSession, !session.isConnected {
            print("[DeviceManager] ⚠️ Persistent session exists but not connected")
            fflush(stdout)
        }
        
        // Persistent session missing or dead - attempt warmStart() with timeout
        // This only happens on:
        // - First access after daemon startup (if warmStart() failed or wasn't called)
        // - Hard failure (write/read failed)
        // - Device disconnect
        // CRITICAL: Add timeout to prevent hanging if Pico isn't connected
        print("[DeviceManager] ⚠️ No persistent session - attempting warmStart() with 5s timeout...")
        fflush(stdout)
        do {
            let warmStartBegin = Date()
            // Use 5s timeout to allow device boot time (USB enumeration + CDC stability + boot messages)
            try await withTimeout(seconds: 5.0) {
                print("[DeviceManager] 🔥 Calling warmStart() inside timeout wrapper...")
                fflush(stdout)
                try await self.warmStart()
                print("[DeviceManager] ✅ warmStart() completed successfully")
                fflush(stdout)
            }
            let warmStartDuration = Date().timeIntervalSince(warmStartBegin)
            print("[DeviceManager] warmStart() took \(String(format: "%.3f", warmStartDuration))s")
            fflush(stdout)
            
            guard let session = persistentSession else {
                print("[DeviceManager] ❌ warmStart() succeeded but persistentSession is still nil")
                fflush(stdout)
                throw NSError(domain: "DeviceManager", code: -2,
                             userInfo: [NSLocalizedDescriptionKey: "Failed to create persistent session"])
            }
            print("[DeviceManager] ✅ Returning newly created persistent session")
            fflush(stdout)
            return session
        } catch {
            // Warm start failed or timed out - throw error immediately with clear message
            let errorMsg = error.localizedDescription
            print("[DeviceManager] ❌ warmStart() failed or timed out: \(errorMsg)")
            fflush(stdout)
            throw NSError(domain: "DeviceManager", code: -3,
                         userInfo: [NSLocalizedDescriptionKey: "Pico device not available: \(errorMsg). Please connect the device and try again."])
        }
    }
    
    /// Helper for timeout wrapper (uses ContinuousClock for monotonic timing)
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }
            
            group.addTask {
                // CLOCK MONOTONICITY: Use ContinuousClock for timeout delays
                try await ContinuousClock().sleep(until: .now + .seconds(Int(seconds)))
                throw NSError(domain: "DeviceManager", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "Operation timed out after \(seconds) seconds"])
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    /// Register a callback invoked on device disconnect (for external state invalidation)
    public func setOnDisconnect(_ callback: @escaping () -> Void) {
        _onDisconnect = callback
    }
    
    /// Set bootloader transition flag (suppresses reconnect during intentional reboot)
    public func setBootloaderTransition(_ value: Bool) {
        _isBootloaderTransition = value
        if value {
            print("[DeviceManager] [FLASH] Bootloader transition started — suppressing reconnect")
        } else {
            print("[DeviceManager] [FLASH] Bootloader transition ended — reconnect re-enabled")
        }
        fflush(stdout)
    }
    
    /// Check if in bootloader transition
    public var isBootloaderTransition: Bool {
        return _isBootloaderTransition
    }
    
    /// Release the serial session without triggering reconnect.
    /// Used before bootloader reboot so the serial port is freed.
    public func releaseSessionForFlash() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        
        if let session = persistentSession {
            session.invalidate()
            session.disconnect()
        }
        persistentSession = nil
        persistentPort = nil
        persistentDeviceID = nil
        sessions.removeAll()
        portPaths.removeAll()
        invalidatePortCache()
        print("[DeviceManager] [FLASH] Session released for bootloader transition")
        fflush(stdout)
    }
    
    /// Device capabilities from the persistent session (populated on connect)
    public var deviceCapabilities: DeviceCapabilities? {
        return persistentSession?.deviceCapabilities
    }
    
    /// Refresh pin map from firmware and return updated pin capabilities
    public func refreshPinMap() async throws -> [PinCapability] {
        let session = try await getSession()
        return try await session.queryPinMap()
    }
    
    /// Get primary device port path.
    /// Fast path: returns cached port immediately.
    /// If nil, tries one inline warmStart as an immediate fallback (the background
    /// monitor will keep retrying regardless, but this gives the current command
    /// a chance to succeed without waiting for the next monitor cycle).
    public func getPrimaryPortPath() async -> String? {
        if persistentPort != nil {
            return persistentPort
        }
        
        ensureDeviceMonitor()
        
        if !isWarmStarting {
            do {
                try await warmStart()
            } catch {
                // Monitor will keep retrying in background
            }
        }
        return persistentPort
    }
    
    /// Auto-detect and connect to all Pico devices
    public func autoDiscover() async throws -> [String] {
        // Find all USB serial devices
        let ports = findPicoPorts()
        var connected: [String] = []
        
        for port in ports {
            do {
                let session = try await getSession(portPath: port)
                connected.append(session.deviceID)
            } catch {
                // Skip devices that fail to connect
                continue
            }
        }
        
        return connected
    }
    
    /// Find all Pico serial ports
    /// RULE 3: Port scan must be cached - only called on startup/reconnect, never per command
    /// Returns cached result if available and fresh (< 60 seconds old)
    public func findPicoPorts() -> [String] {
        // Return cached ports if available and fresh
        if let cached = cachedPorts,
           let timestamp = portScanTimestamp,
           Date().timeIntervalSince(timestamp) < portCacheValiditySeconds {
            return cached
        }
        
        // Cache expired or missing - scan (only happens on startup/reconnect)
        let fileManager = FileManager.default
        let devDir = "/dev"
        
        guard let files = try? fileManager.contentsOfDirectory(atPath: devDir) else {
            cachedPorts = []
            portScanTimestamp = Date()
            return []
        }
        
        let ports = files
            .filter { $0.hasPrefix("cu.usbmodem") }
            .map { "\(devDir)/\($0)" }
            .sorted()
        
        cachedPorts = ports
        portScanTimestamp = Date()
        
        return ports
    }
    
    /// Invalidate port cache (call on reconnect/disconnect)
    public func invalidatePortCache() {
        cachedPorts = nil
        portScanTimestamp = nil
    }
    
    /// Handle hard failure - clear persistent session and attempt reconnect
    /// Serialized via actor isolation + isRecovering flag to prevent reconnect races
    /// CRITICAL GAP #2: Invalidates old session before replacement (prevents zombie FD writes)
    /// Called when write() or read() fails
    public func handleHardFailure() async {
        // During bootloader transition, disconnect is expected — suppress reconnect
        if _isBootloaderTransition {
            print("[DeviceManager] [FLASH] Disconnect during bootloader transition (expected) — suppressing reconnect")
            fflush(stdout)
            return
        }
        
        // If already recovering, skip (prevents multiple concurrent reconnect attempts)
        if isRecovering {
            print("[DeviceManager] Hard failure recovery already in progress - skipping duplicate")
            return
        }
        
        isRecovering = true
        defer { isRecovering = false }
        
        print("[DeviceManager] Hard failure detected - invalidating old session and reconnecting")
        
        // CRITICAL GAP #2: Invalidate old session BEFORE clearing reference
        // This cancels all pending writes/reads and prevents zombie FD operations
        if let oldSession = persistentSession {
            oldSession.invalidate()
            print("[DeviceManager] 🔴 Invalidated old session (deviceID: \(oldSession.deviceID))")
        }
        
        // Clear persistent session (after invalidation)
        // CRITICAL DIAGNOSTIC: Log every session clear with reason
        print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] DeviceManager(id=\(ObjectIdentifier(self))) CLEARING persistentSession")
        print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Reason: handleHardFailure() - hard failure detected")
        print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Previous session state: \(persistentSession != nil ? "exists" : "nil")")
        if let session = persistentSession {
            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Session being cleared: isConnected=\(session.isConnected), isReady=\(session.isReady)")
        }
        fflush(stdout)
        
        persistentSession = nil
        persistentPort = nil
        persistentDeviceID = nil
        
        // Clear stale session entries (port path may change after reconnect)
        for session in sessions.values {
            session.invalidate()
            session.disconnect()
        }
        sessions.removeAll()
        portPaths.removeAll()
        
        // Invalidate port cache so warmStart() scans for new port path
        invalidatePortCache()
        
        // Cancel keepalive and state sync to prevent sending to dead session
        keepaliveTask?.cancel()
        keepaliveTask = nil
        
        // Notify via onDisconnect callback (DeviceStateManager invalidation)
        _onDisconnect?()
        
        // Attempt warmStart() to reconnect (async, non-blocking)
        // PROBLEM 2 FIX: This is now serialized, so no race condition
        do {
            try await warmStart()
            print("[DeviceManager] Hard failure recovery succeeded")
        } catch {
            print("[DeviceManager] Hard failure recovery failed: \(error)")
        }
    }
    
    /// Send command to primary device (uses persistent session)
    public func sendCommand(commandID: CommandID, value: UInt8) async throws {
        let session = try await getSession()
        try await session.sendCommand(commandID: commandID, value: value)
    }
    
    /// Send command to specific device (legacy support)
    public func sendCommand(deviceID: String, commandID: CommandID, value: UInt8) async throws {
        if deviceID == persistentDeviceID, let session = persistentSession {
            try await session.sendCommand(commandID: commandID, value: value)
        } else if let session = sessions[deviceID] {
            try await session.sendCommand(commandID: commandID, value: value)
        } else {
            throw NSError(domain: "DeviceManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Device not found: \(deviceID)"])
        }
    }
    
    /// Send servo angle command (0-180) to primary device
    public func setServo(angle: Int) async throws -> (success: Bool, state: [String: Bool]?) {
        let session = try await getSession()
        return try await session.sendServoCommand(angle: angle)
    }
    
    /// Send keepalive ping (RULE 2)
    public func sendPing() async throws {
        let session = try await getSession()
        try await session.sendCommand(commandID: .queryState, value: 0)
    }
    
    /// Send batched commands to device
    public func sendBatch(deviceID: String, commands: [(CommandID, UInt8)]) async throws {
        // Check persistent session first (primary device may not be in sessions dict)
        if deviceID == persistentDeviceID, let session = persistentSession {
            try await session.sendBatch(commands: commands)
            return
        }
        
        guard let session = sessions[deviceID] else {
            throw NSError(domain: "DeviceManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Device not found: \(deviceID)"])
        }
        
        try await session.sendBatch(commands: commands)
    }
    
    /// Get device status
    public func getDeviceStatus(deviceID: String) async throws -> DeviceInfo? {
        return deviceRegistry[deviceID]
    }
    
    /// Disconnect all sessions
    /// CRITICAL GAP #2: Invalidates sessions before disconnecting
    public func disconnectAll() {
        deviceMonitorTask?.cancel()
        deviceMonitorTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        
        // CRITICAL GAP #2: Invalidate persistent session before disconnecting
        if let session = persistentSession {
            session.invalidate()
            session.disconnect()
        }
        // CRITICAL DIAGNOSTIC: Log every session clear with reason
        print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] DeviceManager(id=\(ObjectIdentifier(self))) CLEARING persistentSession")
        print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Reason: disconnectAll() - explicit disconnect")
        print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Previous session state: \(persistentSession != nil ? "exists" : "nil")")
        if let session = persistentSession {
            print("[DeviceManager] 🔥🔥🔥 [DIAGNOSTIC] Session being cleared: isConnected=\(session.isConnected), isReady=\(session.isReady)")
        }
        fflush(stdout)
        
        persistentSession = nil
        persistentPort = nil
        persistentDeviceID = nil
        
        // CRITICAL GAP #2: Invalidate all sessions before disconnecting
        for session in sessions.values {
            session.invalidate()
            session.disconnect()
        }
        
        sessions.removeAll()
        portPaths.removeAll()
        invalidatePortCache()
    }
    
    // Note: Cancellables stored in isolated context (Combine subscription handled via nonisolated allEvents)
    private var cancellables = Set<AnyCancellable>()
}

/// Device information
public struct DeviceInfo {
    public let deviceID: String
    public let portPath: String
    public let firmware: String?
    public let capabilities: [String]
    public let lastSeen: Date
    public let isReady: Bool
}
