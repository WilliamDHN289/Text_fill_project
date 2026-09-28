import Foundation
import Darwin

/// Logs the reason an app process died (signal, normal exit, etc.) to a persistent
/// file that survives across restarts. Use this to debug unexpected terminations.
///
/// Writes to ~/.autocomplete-death.log (appended, never truncated).
///
/// Signal-safe: uses raw POSIX write() to a pre-opened file descriptor, no Swift runtime.
enum DeathLogger {
    private nonisolated(unsafe) static var fd: Int32 = -1
    private nonisolated(unsafe) static var pid: Int32 = 0
    // Pre-allocated at install() so the signal handler can capture a backtrace
    // without malloc (async-signal-safe). backtrace() fills this buffer;
    // backtrace_symbols_fd() writes it straight to the log fd.
    private nonisolated(unsafe) static var btBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    private static let btCapacity: Int32 = 64

    static func install() {
        // Open the death log file (append mode, create if needed)
        let path = NSHomeDirectory() + "/.autocomplete-death.log"
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd < 0 {
            Log.error("DeathLogger: failed to open \(path)")
            return
        }
        pid = getpid()
        btBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(btCapacity))

        // Log app start so we can correlate with later death entries
        let startMsg = "[\(timestamp())] [pid \(pid)] STARTED\n"
        _ = startMsg.withCString { writeCString($0) }

        // Install signal handlers for termination signals
        let signals: [Int32] = [
            SIGHUP,   // 1  - terminal hangup
            SIGINT,   // 2  - Ctrl-C
            SIGQUIT,  // 3  - Ctrl-\
            SIGILL,   // 4  - illegal instruction
            SIGTRAP,  // 5  - Swift runtime trap (overflow, force-unwrap nil,
                      //      precondition/fatalError, bounds) — the common case
            SIGABRT,  // 6  - abort()
            SIGBUS,   // 10 - bus error
            SIGSEGV,  // 11 - segfault
            SIGPIPE,  // 13 - broken pipe
            SIGTERM,  // 15 - polite kill
            SIGXCPU,  // 24 - CPU time limit
            SIGXFSZ,  // 25 - file size limit
        ]

        for sig in signals {
            // Use sigaction so we get the signal number reliably
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { signum in
                DeathLogger.handleSignal(signum)
            }
            action.sa_flags = 0
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }
    }

    /// Called from `applicationWillTerminate` for normal exits
    static func logNormalExit() {
        guard fd >= 0 else { return }
        let msg = "[\(timestamp())] [pid \(pid)] NORMAL EXIT (applicationWillTerminate)\n"
        _ = msg.withCString { writeCString($0) }
    }

    // MARK: - Signal-safe internals

    /// Signal handler — runs in signal context, must be async-signal-safe.
    /// Only POSIX functions from sigaction(2)'s safe list are allowed here.
    private static func handleSignal(_ signum: Int32) {
        // Build a fixed-size message in stack memory (no malloc)
        var buffer = [CChar](repeating: 0, count: 128)
        let prefix: StaticString = "[pid "
        let middle: StaticString = "] DIED FROM SIGNAL "
        let suffix: StaticString = "\n"

        var pos = 0
        pos = appendStaticString(prefix, into: &buffer, at: pos)
        pos = appendInt(Int(pid), into: &buffer, at: pos)
        pos = appendStaticString(middle, into: &buffer, at: pos)
        pos = appendInt(Int(signum), into: &buffer, at: pos)
        pos = appendStaticString(suffix, into: &buffer, at: pos)

        if fd >= 0 {
            _ = write(fd, buffer, pos)
            // Capture the crashing call stack. backtrace() fills the pre-allocated
            // buffer (no malloc) and backtrace_symbols_fd() writes frames directly
            // to fd — both async-signal-safe, unlike backtrace_symbols(). Frames
            // are image+offset (the .ips report has full symbolication); this makes
            // the death log self-sufficient for "where did it trap".
            if let buf = btBuffer {
                let n = backtrace(buf, btCapacity)
                backtrace_symbols_fd(buf, n, fd)
            }
            fsync(fd)
        }

        // Re-raise default handler so the process actually dies
        signal(signum, SIG_DFL)
        raise(signum)
    }

    private static func appendStaticString(_ str: StaticString, into buffer: inout [CChar], at pos: Int) -> Int {
        var p = pos
        str.withUTF8Buffer { bytes in
            for byte in bytes where p < buffer.count - 1 {
                buffer[p] = CChar(bitPattern: byte)
                p += 1
            }
        }
        return p
    }

    private static func appendInt(_ value: Int, into buffer: inout [CChar], at pos: Int) -> Int {
        if value == 0 {
            if pos < buffer.count - 1 {
                buffer[pos] = CChar(48) // '0'
                return pos + 1
            }
            return pos
        }
        var n = value
        var digits = [CChar]()
        digits.reserveCapacity(20)
        while n > 0 {
            digits.append(CChar(48 + (n % 10))) // '0' + digit
            n /= 10
        }
        var p = pos
        for d in digits.reversed() where p < buffer.count - 1 {
            buffer[p] = d
            p += 1
        }
        return p
    }

    private static func writeCString(_ cstr: UnsafePointer<CChar>) -> Int {
        let len = strlen(cstr)
        return write(fd, cstr, len)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
