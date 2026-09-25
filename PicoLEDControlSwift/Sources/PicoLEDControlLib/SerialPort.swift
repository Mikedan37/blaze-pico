import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Serial port communication for macOS using POSIX termios
public class SerialPort {
    private var fileDescriptor: Int32 = -1
    private let path: String
    
    public init(path: String) {
        self.path = path
    }
    
    /// Check if port is open
    public var isOpen: Bool {
        return fileDescriptor >= 0
    }
    
    /// Open the serial port with specified baud rate
    public func open(baudRate: Int = 115200) throws {
        // Ignore SIGPIPE process-wide so writes to a disconnected USB CDC
        // return EPIPE instead of killing the process. Safe to call multiple times.
        signal(SIGPIPE, SIG_IGN)
        
        fileDescriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fileDescriptor >= 0 else {
            throw SerialPortError.failedToOpen(path: path, errno: Darwin.errno)
        }
        
        // Get current options
        var options = termios()
        guard tcgetattr(fileDescriptor, &options) == 0 else {
            let err = Darwin.errno
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
            throw SerialPortError.failedToGetAttributes(errno: err)
        }
        
        // Configure for raw binary I/O
        cfmakeraw(&options)
        
        // CLOCAL: ignore modem control lines (prevents blocking on DCD for USB CDC)
        // CREAD: enable receiver (already set by cfmakeraw, but be explicit)
        // ~HUPCL: do NOT drop DTR on close — prevents Pico from seeing a USB disconnect
        //         when the host process exits, keeping GPIO state stable between invocations
        // ~CRTSCTS: disable hardware flow control (USB CDC handles its own)
        options.c_cflag |= UInt(CLOCAL | CREAD)
        options.c_cflag &= ~UInt(CRTSCTS | HUPCL)
        
        // VMIN=0, VTIME=1: non-blocking reads with 100ms timeout
        withUnsafeMutableBytes(of: &options.c_cc) { bytes in
            bytes[Int(VMIN)] = 0
            bytes[Int(VTIME)] = 1
        }
        
        // Set baud rate
        let speed = speed_t(baudRate)
        guard cfsetspeed(&options, speed) == 0 else {
            let err = Darwin.errno
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
            throw SerialPortError.failedToSetBaudRate(baudRate: baudRate)
        }
        
        // Set options
        guard tcsetattr(fileDescriptor, TCSANOW, &options) == 0 else {
            let err = Darwin.errno
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
            throw SerialPortError.failedToSetAttributes(errno: err)
        }
        
        // Flush any pending data
        tcflush(fileDescriptor, TCIOFLUSH)
        
        // Keep O_NONBLOCK set. Blocking writes hang on macOS USB CDC.
        // Non-blocking writes return EAGAIN when buffer is full, which we retry.
        // Non-blocking reads with VMIN=0/VTIME=1 return after 100ms timeout.
        
        // Small delay after opening to ensure USB CDC is ready
        usleep(50_000) // 50ms delay
    }
    
    /// Write data to the serial port in non-blocking mode.
    /// Retries on EAGAIN (buffer temporarily full) with exponential backoff.
    /// For small serial packets (< 64 bytes), first attempt almost always succeeds.
    public func write(_ data: Data) throws {
        guard fileDescriptor >= 0 else {
            throw SerialPortError.notOpen
        }
        
        var remaining = data
        let startTime = Date()
        let maxTimeoutSeconds = 2.0
        var retryDelayUs: useconds_t = 500 // start at 0.5ms, back off exponentially
        
        while !remaining.isEmpty {
            if Date().timeIntervalSince(startTime) > maxTimeoutSeconds {
                throw SerialPortError.writeFailed(bytesWritten: -1, expected: data.count, errno: 60)
            }
            
            let bytesWritten = remaining.withUnsafeBytes { bytes in
                Darwin.write(fileDescriptor, bytes.baseAddress, remaining.count)
            }
            
            if bytesWritten == remaining.count {
                return
            }
            
            if bytesWritten > 0 {
                remaining = remaining.advanced(by: bytesWritten)
                retryDelayUs = 500 // reset backoff on partial progress
                continue
            }
            
            if bytesWritten == -1 {
                let errnoValue = Darwin.errno
                if errnoValue == EINTR {
                    continue
                }
                if errnoValue == EAGAIN || errnoValue == EWOULDBLOCK {
                    usleep(retryDelayUs)
                    retryDelayUs = min(retryDelayUs * 2, 50_000) // cap at 50ms
                    continue
                }
                throw SerialPortError.writeFailed(bytesWritten: -1, expected: data.count, errno: errnoValue)
            }
        }
    }
    
    /// Read data from serial port with timeout using poll() for reliable data detection.
    /// O_NONBLOCK + busy-wait with usleep misses data on macOS USB CDC; poll() is
    /// the correct way to wait for the kernel to signal data availability.
    public func read(maxBytes: Int = 256, timeoutMs: Int = 500) throws -> Data {
        guard fileDescriptor >= 0 else {
            throw SerialPortError.notOpen
        }
        
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        var totalRead = Data()
        let startTime = Date()
        
        while true {
            let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let remainingMs = timeoutMs - elapsedMs
            if remainingMs <= 0 { break }
            
            var pfd = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&pfd, 1, Int32(min(remainingMs, 100)))
            
            if pollResult > 0 {
                // POLLHUP/POLLERR = serial device disconnected (stale FD)
                let revents = pfd.revents
                if (revents & Int16(POLLHUP)) != 0 || (revents & Int16(POLLERR)) != 0 {
                    if !totalRead.isEmpty { return totalRead }
                    throw SerialPortError.readFailed(errno: ENXIO)
                }
                
                if (revents & Int16(POLLIN)) != 0 {
                    let bytesRead = Darwin.read(fileDescriptor, &buffer, maxBytes)
                    if bytesRead > 0 {
                        totalRead.append(contentsOf: buffer.prefix(bytesRead))
                        if buffer.prefix(bytesRead).contains(0x0A) { // newline
                            return totalRead
                        }
                    } else if bytesRead == 0 {
                        // EOF — device disconnected
                        if !totalRead.isEmpty { return totalRead }
                        throw SerialPortError.readFailed(errno: ENXIO)
                    } else {
                        let e = Darwin.errno
                        if e == EAGAIN || e == EWOULDBLOCK || e == EINTR { continue }
                        throw SerialPortError.readFailed(errno: e)
                    }
                }
            } else if pollResult < 0 {
                let e = Darwin.errno
                if e == EINTR { continue }
                throw SerialPortError.readFailed(errno: e)
            }
            // pollResult == 0 → timeout, loop to check remaining time
        }
        
        return totalRead
    }
    
    /// Close the serial port
    public func close() {
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }
    
    deinit {
        close()
    }
}

public enum SerialPortError: Error, LocalizedError {
    case failedToOpen(path: String, errno: Int32)
    case failedToGetAttributes(errno: Int32)
    case failedToSetAttributes(errno: Int32)
    case failedToSetBaudRate(baudRate: Int)
    case notOpen
    case writeFailed(bytesWritten: Int, expected: Int, errno: Int32)
    case readFailed(errno: Int32)
    
    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let path, let errno):
            return "Failed to open serial port \(path): errno=\(errno) (\(SerialPortError.errnoDescription(errno)))"
        case .failedToGetAttributes(let errno):
            return "Failed to get serial port attributes: errno=\(errno) (\(SerialPortError.errnoDescription(errno)))"
        case .failedToSetAttributes(let errno):
            return "Failed to set serial port attributes: errno=\(errno) (\(SerialPortError.errnoDescription(errno)))"
        case .failedToSetBaudRate(let baudRate):
            return "Failed to set baud rate to \(baudRate)"
        case .notOpen:
            return "Serial port is not open"
        case .readFailed(let errno):
            return "Read failed: errno=\(errno) (\(SerialPortError.errnoDescription(errno)))"
        case .writeFailed(let written, let expected, let errno):
            if written == -1 {
                // Complete write failure - check errno for specific reason
                let errMsg = SerialPortError.errnoDescription(errno)
                if errno == EBADF {
                    return "Write failed: file descriptor invalid (port may be closed or disconnected). errno=\(errno) (\(errMsg))"
                } else if errno == EIO {
                    return "Write failed: I/O error (device may be disconnected). errno=\(errno) (\(errMsg))"
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return "Write failed: operation would block (port may be busy or locked by another process). errno=\(errno) (\(errMsg))"
                } else {
                    return "Write failed: wrote -1 bytes, expected \(expected). errno=\(errno) (\(errMsg))"
                }
            } else {
                // Partial write (unexpected with non-blocking mode)
                return "Write failed: partial write (\(written)/\(expected) bytes). errno=\(errno) (\(SerialPortError.errnoDescription(errno)))"
            }
        }
    }
    
    /// Classifies whether this error means the device is truly gone (fd invalid, hardware error)
    /// vs a transient issue (buffer full, timeout, signal interrupt).
    /// Only fatal errors should kill the session. Transient errors should be surfaced
    /// to the caller but leave the session alive for the next command.
    public var isFatal: Bool {
        switch self {
        case .notOpen:
            return true
        case .failedToOpen, .failedToGetAttributes, .failedToSetAttributes, .failedToSetBaudRate:
            return true
        case .readFailed(let errno):
            switch errno {
            case EBADF, EIO, EINVAL, ENXIO, ENODEV:
                return true
            default:
                return false
            }
        case .writeFailed(_, _, let errno):
            switch errno {
            case EBADF, EIO, EINVAL, ENXIO, ENODEV, EPIPE:
                return true
            default:
                return false
            }
        }
    }
    
    private static func errnoDescription(_ errno: Int32) -> String {
        if let cString = strerror(errno) {
            return String(cString: cString)
        }
        return "Unknown error"
    }
}
