import Foundation

enum LogLevel: Int, Comparable, CaseIterable, Identifiable {
    case debug, info, warn, error

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .debug: return "Debug"
        case .info:  return "Info"
        case .warn:  return "Warn"
        case .error: return "Error"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct LogEntry: Identifiable, Hashable {
    let id: UInt64
    let date: Date
    let level: LogLevel
    let context: String?
    let message: String
    let detail: String?
}

/// Foundation-only relay, so `Subprocess` (and any other I/O code that should
/// stay linkable into a headless CLI) never needs SwiftUI just to record a
/// line. `LogStore` is the sole observer, registered via `onAppend` - it owns
/// ids, timestamps and the actual buffer.
enum LogSink {
    /// Set once by `LogStore`. Fires on whatever thread `record` runs on -
    /// the observer hops to whatever isolation it needs itself.
    static var onAppend: ((LogLevel, String, String?, String?) -> Void)?

    /// Callable from any isolation domain - most call sites are off the main
    /// thread (subprocess pipe reads, background actors).
    static func record(_ level: LogLevel,
                       _ message: String,
                       context: String? = nil,
                       detail: String? = nil) {
        onAppend?(level, message, context, detail)
    }
}
