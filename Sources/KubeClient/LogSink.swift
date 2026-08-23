import Foundation
import KubeModel

public enum LogLevel: Int, Comparable, CaseIterable, Identifiable {
    case debug, info, warn, error

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .debug: return "Debug"
        case .info:  return "Info"
        case .warn:  return "Warn"
        case .error: return "Error"
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LogEntry: Identifiable, Hashable {
    public let id: UInt64
    public let date: Date
    public let level: LogLevel
    public let context: String?
    public let message: String
    public let detail: String?

    /// The synthesized memberwise init is `internal` even on a `public`
    /// struct - `LogStore` (KubeViewKit) constructs these directly, so it
    /// needs one explicitly.
    public init(id: UInt64, date: Date, level: LogLevel, context: String?, message: String, detail: String?) {
        self.id = id
        self.date = date
        self.level = level
        self.context = context
        self.message = message
        self.detail = detail
    }
}

/// Foundation-only relay, so `Subprocess` (and any other I/O code that should
/// stay linkable into a headless CLI) never needs SwiftUI just to record a
/// line. `LogStore` is the sole observer, registered via `onAppend` - it owns
/// ids, timestamps and the actual buffer.
public enum LogSink {
    /// Set once by `LogStore`. Fires on whatever thread `record` runs on -
    /// the observer hops to whatever isolation it needs itself.
    public static var onAppend: ((LogLevel, String, String?, String?) -> Void)?

    /// Callable from any isolation domain - most call sites are off the main
    /// thread (subprocess pipe reads, background actors). Internal on
    /// purpose: every current caller (`Subprocess`) lives inside this module;
    /// consumers only ever set `onAppend`, never call `record` themselves.
    static func record(_ level: LogLevel,
                       _ message: String,
                       context: String? = nil,
                       detail: String? = nil) {
        onAppend?(level, message, context, detail)
    }
}
