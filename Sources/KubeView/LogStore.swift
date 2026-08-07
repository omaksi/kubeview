import Foundation
import SwiftUI

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

    var color: Color {
        switch self {
        case .debug: return .secondary
        case .info:  return .primary
        case .warn:  return .orange
        case .error: return .red
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

/// In-memory ring buffer behind the Diagnostics view. Deliberately not written
/// to disk: entries carry namespace and resource names, and a viewer app has no
/// business leaving that on the filesystem unasked.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var entries: [LogEntry] = []

    private var nextID: UInt64 = 0
    private let cap = 2000
    private let slack = 200

    /// Callable from any isolation domain — `KubectlService` is an actor and
    /// most call sites are off the main thread.
    nonisolated static func record(_ level: LogLevel,
                                   _ message: String,
                                   context: String? = nil,
                                   detail: String? = nil) {
        Task { @MainActor in
            shared.append(level, message, context: context, detail: detail)
        }
    }

    func append(_ level: LogLevel, _ message: String, context: String? = nil, detail: String? = nil) {
        entries.append(LogEntry(id: nextID, date: Date(), level: level,
                                context: context, message: message, detail: detail))
        nextID &+= 1
        // Trim in batches — removeFirst(1) per append is O(n) every time.
        if entries.count > cap + slack {
            entries.removeFirst(entries.count - cap)
        }
    }

    func clear() { entries.removeAll() }
}

// MARK: - Report

extension LogStore {
    /// Redaction is best-effort and deliberately conservative about claiming
    /// more: it maps context names to stable aliases and masks hosts, IPs and
    /// bearer tokens in free-text detail. It cannot know that a given resource
    /// name is sensitive, so the Diagnostics view says so next to the toggle.
    func report(redacted: Bool, contexts: [String], appVersion: String) -> String {
        var aliases: [String: String] = [:]
        for (i, ctx) in contexts.enumerated() { aliases[ctx] = "cluster-\(i + 1)" }

        func scrub(_ s: String) -> String {
            guard redacted else { return s }
            var out = s
            for (real, alias) in aliases where !real.isEmpty {
                // Word-bounded: a context named `default` would otherwise rewrite
                // every occurrence of the substring, turning kubectl's "defaulted
                // container" into "cluster-2ed container".
                let escaped = NSRegularExpression.escapedPattern(for: real)
                out = out.replacingOccurrences(of: "\\b\(escaped)\\b", with: alias,
                                               options: .regularExpression)
            }
            // Resource identifiers only ever reach the log via kubectl argv, so
            // mask them there. Command shape and timings — the parts worth
            // reading — survive intact.
            for (pattern, template) in [
                (#"(-n|--namespace)\s+\S+"#, "$1 <ns>"),
                (#"(describe\s+\S+\s+)\S+"#, "$1<name>"),
                (#"(logs\s+)(?!-)\S+"#, "$1<pod>"),
            ] {
                out = out.replacingOccurrences(of: pattern, with: template,
                                               options: .regularExpression)
            }
            for pattern in [
                #"https?://[^\s"']+"#,
                #"\b\d{1,3}(\.\d{1,3}){3}\b"#,
                #"(?i)bearer\s+[A-Za-z0-9._\-]+"#,
            ] {
                out = out.replacingOccurrences(of: pattern, with: "<redacted>",
                                               options: .regularExpression)
            }
            return out
        }

        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines: [String] = [
            "## KubeView diagnostics",
            "",
            "- App: \(appVersion)",
            "- macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "- Contexts: \(contexts.count)",
            "- Redacted: \(redacted ? "yes" : "no")",
            "",
            "### Log (\(entries.count) entries)",
            "",
            "```",
        ]
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        for e in entries {
            let ctx = e.context.map { " [\(scrub($0))]" } ?? ""
            lines.append("\(fmt.string(from: e.date)) \(e.level.label.uppercased())\(ctx) \(scrub(e.message))")
            if let d = e.detail, !d.isEmpty {
                for line in scrub(d).split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("    \(line)")
                }
            }
        }
        lines.append("```")
        return lines.joined(separator: "\n")
    }
}
