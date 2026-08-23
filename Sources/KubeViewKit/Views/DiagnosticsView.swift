import SwiftUI
import AppKit
import KubeModel
import KubeClient
import KubeUI

struct DiagnosticsView: View {
    @EnvironmentObject var logs: LogStore
    @EnvironmentObject var manager: ClusterManager

    @State private var minLevel: LogLevel = .debug
    @State private var query: String = ""
    @State private var follow = true
    @State private var redact = true
    @State private var copied = false
    @State private var showingFeedback = false

    private var filtered: [LogEntry] {
        logs.entries.filter { e in
            guard e.level >= minLevel else { return false }
            guard !query.isEmpty else { return true }
            return e.message.localizedCaseInsensitiveContains(query)
                || (e.detail?.localizedCaseInsensitiveContains(query) ?? false)
                || (e.context?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                logList
            }
            Divider()
            footer
        }
        .sheet(isPresented: $showingFeedback) {
            FeedbackSheet()
                .environmentObject(logs)
                .environmentObject(manager)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $minLevel) {
                ForEach(LogLevel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

            Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)

            Spacer()

            Text("\(filtered.count) / \(logs.entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button("Clear") { logs.clear() }
                .controlSize(.small)
        }
        .padding(8)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(logs.entries.isEmpty ? "No log entries yet" : "Nothing matches this filter")
                .font(.callout)
                .foregroundStyle(.secondary)
            if logs.entries.isEmpty {
                Text("Entries appear as refresh cycles run — every kubectl call is recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { LogRow(entry: $0) }
                }
            }
            .onChange(of: filtered.last?.id) { _, id in
                guard follow, let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Redact hosts, IPs and context names", isOn: $redact)
                .toggleStyle(.checkbox)
            Text("Resource and namespace names are not redacted — review before sharing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(copied ? "Copied" : "Copy Report") { copyReport() }
                .controlSize(.small)
            Button("Save Report…") { saveReport() }
                .controlSize(.small)
            Button("Report Feedback…") { showingFeedback = true }
                .controlSize(.small)
        }
        .padding(8)
        .background(.bar)
    }

    // MARK: - Actions

    private func makeReport() -> String {
        logs.report(redacted: redact,
                    contexts: manager.activeOrder,
                    appVersion: Bundle.main.appVersion)
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(makeReport(), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kubeview-diagnostics.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? makeReport().write(to: url, atomically: true, encoding: .utf8)
    }

}

private struct LogRow: View {
    let entry: LogEntry
    @State private var expanded = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 8) {
                Text(Self.formatter.string(from: entry.date))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(entry.level.label.uppercased())
                    .font(.caption2.monospaced())
                    .foregroundStyle(entry.level.color)
                    .frame(width: 44, alignment: .leading)
                if let ctx = entry.context {
                    Text(ctx)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(entry.message)
                    .font(.caption.monospaced())
                    .foregroundStyle(entry.level >= .warn ? entry.level.color : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if entry.detail != nil {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if expanded, let detail = entry.detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if entry.detail != nil { expanded.toggle() } }
    }
}

extension Bundle {
    var appVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "v\(v)"
    }
}
