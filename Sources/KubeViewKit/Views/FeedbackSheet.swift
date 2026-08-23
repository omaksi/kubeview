import SwiftUI
import AppKit
import KubeModel
import KubeClient
import KubeUI

struct FeedbackSheet: View {
    @EnvironmentObject var logs: LogStore
    @EnvironmentObject var manager: ClusterManager
    @Environment(\.dismiss) private var dismiss

    @State private var summary = ""
    @State private var detail = ""
    @State private var includeLogs = true
    @State private var showingPayload = false
    @State private var sending = false
    @State private var failure: String?
    @State private var created: URL?

    private var diagnostics: String {
        // Always redacted. The issue is public — this is not the user's call to
        // make on a whim, so there is no toggle here (unlike Copy/Save Report,
        // which stays local).
        logs.report(redacted: true,
                    contexts: manager.activeOrder,
                    appVersion: Bundle.main.appVersion)
    }

    private var report: FeedbackReport {
        FeedbackReport.build(summary: summary.isEmpty ? "Feedback" : summary,
                             detail: detail,
                             diagnostics: includeLogs ? diagnostics : "_Logs not included._")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let created {
                success(created)
            } else {
                form
            }
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(maxHeight: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Report Feedback").font(.headline)
            Text("Opens a public issue on github.com/omaksi/kubeview")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Summary", text: $summary)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 4) {
                    Text("What happened?").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $detail)
                        .font(.body)
                        .frame(height: 100)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                }

                Toggle("Attach diagnostics log (\(logs.entries.count) entries)", isOn: $includeLogs)
                    .toggleStyle(.checkbox)

                warning

                DisclosureGroup("Review exactly what will be posted", isExpanded: $showingPayload) {
                    ScrollView {
                        Text(report.body)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 200)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
                .font(.caption)

                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text("This becomes a **public** issue. Context names, hosts, IPs and the pod and "
                 + "namespace names in kubectl commands are masked — but text returned by your "
                 + "cluster can still name things. Read the payload below before sending.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func success(_ url: URL) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Issue created").font(.headline)
            Link(url.absoluteString, destination: url)
                .font(.caption.monospaced())
        }
        .frame(maxWidth: .infinity)
        .padding(30)
    }

    private var footer: some View {
        HStack {
            if created == nil {
                Button("Copy Instead") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.body, forType: .string)
                }
                .controlSize(.small)
                .help("Copy the payload so you can paste it into an issue yourself")
            }
            Spacer()
            Button(created == nil ? "Cancel" : "Close") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            if created == nil {
                Button(sending ? "Sending…" : "Send") { send() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || summary.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    private func send() {
        sending = true
        failure = nil
        let payload = report
        Task {
            defer { sending = false }
            guard let token = Keychain.get(Keychain.githubTokenAccount), !token.isEmpty else {
                failure = FeedbackError.noToken.localizedDescription
                return
            }
            do {
                created = try await GitHubIssueTransport().send(payload, token: token)
                LogStore.record(.info, "feedback issue created")
            } catch {
                failure = error.localizedDescription
                LogStore.record(.warn, "feedback send failed", detail: error.localizedDescription)
            }
        }
    }
}
