import SwiftUI

enum PodDetailTab: String, CaseIterable, Identifiable {
    case overview, logs, describe
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .logs: return "Logs"
        case .describe: return "Describe"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "info.circle"
        case .logs: return "text.alignleft"
        case .describe: return "doc.text"
        }
    }
}

@MainActor
final class PodLogsLoader: ObservableObject {
    @Published var text: String = ""
    @Published var loading = false
    @Published var error: String?
    @Published var container: String = ""
    @Published var previous: Bool = false
    @Published var tailLines: Int = 500
    private let kubectl = KubectlService()

    func load(namespace: String, pod: String) async {
        loading = true
        defer { loading = false }
        do {
            let c = container.isEmpty ? nil : container
            text = try await kubectl.logs(namespace: namespace, pod: pod,
                                          container: c, tailLines: tailLines,
                                          previous: previous)
            error = nil
        } catch {
            self.error = error.localizedDescription
            self.text = ""
        }
    }
}

struct PodLogsView: View {
    let route: PodRoute
    let containers: [String]
    @StateObject private var loader = PodLogsLoader()
    @State private var filter: String = ""

    var filtered: String {
        guard !filter.isEmpty else { return loader.text }
        let q = filter.lowercased()
        return loader.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.lowercased().contains(q) }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .task(id: route) {
            if loader.container.isEmpty, let first = containers.first {
                loader.container = first
            }
            await loader.load(namespace: route.namespace, pod: route.name)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if containers.count > 1 {
                Picker("Container", selection: $loader.container) {
                    ForEach(containers, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .onChange(of: loader.container) { _, _ in
                    Task { await loader.load(namespace: route.namespace, pod: route.name) }
                }
            } else if let only = containers.first {
                Text(only).font(.caption.monospaced()).foregroundStyle(.secondary)
            }

            Picker("Tail", selection: $loader.tailLines) {
                Text("100").tag(100)
                Text("500").tag(500)
                Text("1000").tag(1000)
                Text("5000").tag(5000)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .onChange(of: loader.tailLines) { _, _ in
                Task { await loader.load(namespace: route.namespace, pod: route.name) }
            }

            Toggle("Previous", isOn: $loader.previous)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: loader.previous) { _, _ in
                    Task { await loader.load(namespace: route.namespace, pod: route.name) }
                }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Filter lines", text: $filter)
                    .textFieldStyle(.plain)
                    .frame(width: 160)
            }

            Button {
                Task { await loader.load(namespace: route.namespace, pod: route.name) }
            } label: {
                if loader.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(loader.loading)

            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(loader.text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy all logs")
            .disabled(loader.text.isEmpty)
        }
        .padding(8)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if let err = loader.error {
            VStack(alignment: .leading, spacing: 6) {
                Label("Failed to load logs", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(err).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if loader.text.isEmpty && !loader.loading {
            Text("No log lines")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(filtered)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

@MainActor
final class PodDescribeLoader: ObservableObject {
    @Published var text: String = ""
    @Published var loading = false
    @Published var error: String?
    private let kubectl = KubectlService()

    func load(route: PodRoute) async {
        loading = true
        defer { loading = false }
        do {
            text = try await kubectl.describe(namespace: route.namespace, pod: route.name)
            error = nil
        } catch {
            self.error = error.localizedDescription
            self.text = ""
        }
    }
}

struct PodDescribeView: View {
    let route: PodRoute
    @StateObject private var loader = PodDescribeLoader()
    @State private var filter: String = ""

    var filtered: String {
        guard !filter.isEmpty else { return loader.text }
        let q = filter.lowercased()
        return loader.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.lowercased().contains(q) }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.plain)
                        .frame(width: 200)
                }
                Spacer()
                Button {
                    Task { await loader.load(route: route) }
                } label: {
                    if loader.loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(loader.loading)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(loader.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy all")
                .disabled(loader.text.isEmpty)
            }
            .padding(8)
            .background(.bar)
            Divider()

            if let err = loader.error {
                Text(err).font(.caption.monospaced()).foregroundStyle(.red).padding()
            } else if loader.text.isEmpty && !loader.loading {
                Text("Nothing to show").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(filtered)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .task(id: route) { await loader.load(route: route) }
    }
}
