import Foundation
import SwiftUI
import KubeModel
import KubeClient
import KubeUI

/// `LogLevel`/`LogEntry` live in `Services/LogSink.swift` (Foundation-only).
/// `.color` is SwiftUI, so it stays behind here rather than pulling SwiftUI
/// into the I/O-side sink.
extension LogLevel {
    var color: Color {
        switch self {
        case .debug: return .secondary
        case .info:  return .primary
        case .warn:  return .orange
        case .error: return .red
        }
    }
}

/// In-memory ring buffer behind the Diagnostics view. Deliberately not written
/// to disk: entries carry namespace and resource names, and a viewer app has no
/// business leaving that on the filesystem unasked.
///
/// `LogSink` (Foundation-only, so `Subprocess` can call it without depending
/// on SwiftUI) is a pure relay with no storage of its own - this class is
/// where entries actually live, appended on the main actor as they arrive
/// through `onAppend`.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var entries: [LogEntry] = []

    private var nextID: UInt64 = 0
    private let cap = 2000
    private let slack = 200

    init() {
        LogSink.onAppend = { [weak self] level, message, context, detail in
            Task { @MainActor in
                self?.append(level, message, context: context, detail: detail)
            }
        }
    }

    /// Callable from any isolation domain — most call sites (`ClusterStore`,
    /// `AwsStore`) log directly; `Subprocess` logs via `LogSink` instead so it
    /// stays Foundation-only, and its entries arrive here through `onAppend`.
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
