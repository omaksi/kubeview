import SwiftUI

/// The lookback the analysis reasons over.
///
/// Offered rather than free-form because the choice is not really continuous:
/// a day answers "what changed since the deploy", two weeks answers "what does
/// this normally do", and the values in between behave the same as one of those
/// two. `rawValue` is passed straight through to the analyser.
enum LgtmWindow: String, CaseIterable, Identifiable {
    case d1 = "1d", d7 = "7d", d14 = "14d", d30 = "30d"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .d1:  return "24h"
        case .d7:  return "7d"
        case .d14: return "14d"
        case .d30: return "30d"
        }
    }

    /// 24h by default. Longer windows cost more to query - the analyser runs a
    /// subquery per pod per metric, so 1d takes ~6s where 14d takes ~19s and 30d
    /// takes two minutes - and the store this was built against retains only
    /// about 8 days anyway, so the long options promise history that is not
    /// there. A day is also the right default question: what changed since the
    /// last deploy.
    static let `default` = LgtmWindow.d1

    static func stored(for context: String) -> LgtmWindow {
        let raw = UserDefaults.standard.string(forKey: key(context)) ?? ""
        return LgtmWindow(rawValue: raw) ?? .default
    }

    static func key(_ context: String) -> String { "kubeview.lgtm.window.\(context)" }
}

/// Which face of the stack you are looking at. The order is the debugging
/// order: what is true now, what has been true, then what to do about it.
enum LgtmTab: String, CaseIterable, Identifiable {
    case cluster, metrics, findings

    var id: String { rawValue }

    // Persisted per context, because the workspace tab it sits inside is
    // persisted too - a sub-tab that silently resets to Cluster on every visit
    // would be the one part of the window that forgets where you were.
    static func stored(for context: String) -> LgtmTab {
        LgtmTab(rawValue: UserDefaults.standard.string(forKey: key(context)) ?? "") ?? .cluster
    }

    static func key(_ context: String) -> String { "kubeview.lgtm.tab.\(context)" }

    var title: String {
        switch self {
        case .cluster:  return "Cluster"
        case .metrics:  return "Metrics"
        case .findings: return "Findings"
        }
    }

    var icon: String {
        switch self {
        case .cluster:  return "square.stack.3d.up"
        case .metrics:  return "chart.xyaxis.line"
        case .findings: return "checklist"
        }
    }
}

/// Two passes, because they fail independently and one of them is fast.
///
/// The classification pass reads only the Kubernetes API: which workloads exist,
/// what they are, how many replicas are ready. It lands in a couple of seconds
/// and it keeps working when the metrics store is the thing that is broken -
/// which is exactly the situation someone opens this view to investigate.
///
/// The full pass adds history from the stack's own Mimir and the findings
/// derived from it. It is slower and much more fragile, so it must never be
/// what stands between the operator and a first paint.
///
/// Cached per context so navigating away and back does not re-run either one.
@MainActor
final class LgtmStore: ObservableObject {
    @Published private(set) var fast: LgtmReport?
    @Published private(set) var full: LgtmReport?
    @Published private(set) var error: String?
    @Published private(set) var running = false
    @Published private(set) var startedAt: Date?

    @Published var window: LgtmWindow {
        didSet {
            guard window != oldValue else { return }
            UserDefaults.standard.set(window.rawValue, forKey: LgtmWindow.key(context))
            // Only the metrics pass depends on the window; the classification
            // pass describes the present and is the same at any lookback.
            Task { await reloadMetrics() }
        }
    }

    let context: String

    private init(context: String) {
        self.context = context
        self.window = LgtmWindow.stored(for: context)
        #if DEBUG
        LgtmService.selfCheck()
        // Owned by LgtmClusterView.swift; called from here because that file is
        // views only and has no init to hang it off.
        LgtmClusterViewSelfCheck.run()
        // Owned by LgtmTopology.swift / LgtmGraphView.swift, same reason.
        LgtmTopology.selfCheck()
        LgtmGraphLayout.selfCheck()
        #endif
    }

    private static var cache: [String: LgtmStore] = [:]
    static func shared(context: String) -> LgtmStore {
        if let existing = cache[context] { return existing }
        let store = LgtmStore(context: context)
        cache[context] = store
        return store
    }

    var installed: Bool { LgtmService.binary != nil }

    /// The report the Cluster tab draws from: the fast pass when it has landed,
    /// otherwise the full one, since it carries the same classification.
    var classification: LgtmReport? { fast ?? full }

    var hasLoaded: Bool { fast != nil || full != nil }

    func loadIfNeeded() async {
        guard installed, !hasLoaded, error == nil, !running else { return }
        await load()
    }

    func load() async {
        guard !running else { return }
        running = true
        startedAt = Date()
        error = nil
        defer { running = false; startedAt = nil }

        // Classification first, and its failure is not reported on its own: if
        // the cluster is genuinely unreachable the metrics pass is about to say
        // so with a better message, and an older analyser that predates
        // --no-metrics fails here harmlessly.
        if let quick = try? await LgtmService.analyze(context: context, window: window, metrics: false) {
            fast = quick
        }

        do {
            full = try await LgtmService.analyze(context: context, window: window)
        } catch {
            // Keep whatever is already on screen: a failed refresh should not
            // erase numbers that were true a minute ago.
            self.error = (error as? KubectlError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Re-runs only the metrics pass, for a window change.
    func reloadMetrics() async {
        guard installed, !running else { return }
        running = true
        startedAt = Date()
        error = nil
        defer { running = false; startedAt = nil }

        do {
            full = try await LgtmService.analyze(context: context, window: window)
        } catch {
            self.error = (error as? KubectlError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - View

struct LgtmRootView: View {
    @StateObject private var lgtm: LgtmStore
    @State private var tab: LgtmTab

    init(context: String) {
        _lgtm = StateObject(wrappedValue: LgtmStore.shared(context: context))
        _tab = State(initialValue: LgtmTab.stored(for: context))
    }

    var body: some View {
        Group {
            if !lgtm.installed {
                notInstalled
            } else if !lgtm.hasLoaded && lgtm.running {
                loading
            } else if !lgtm.hasLoaded, let error = lgtm.error {
                failed(error)
            } else {
                tabbed
            }
        }
        .task { await lgtm.loadIfNeeded() }
        .onChange(of: tab) { _, new in
            UserDefaults.standard.set(new.rawValue, forKey: LgtmTab.key(lgtm.context))
        }
    }

    private var tabbed: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .cluster:
                LgtmClusterView(report: lgtm.classification)
            case .metrics:
                if let full = lgtm.full {
                    LgtmMetricsView(report: full)
                } else {
                    pending("Metrics")
                }
            case .findings:
                if let full = lgtm.full {
                    LgtmFindingsView(report: full)
                } else {
                    pending("Findings")
                }
            }
        }
    }

    /// Shown while the metrics pass is still running, or after it failed. The
    /// Cluster tab is already usable at this point, so this says so rather than
    /// leaving the window looking broken.
    @ViewBuilder
    private func pending(_ what: String) -> some View {
        VStack(spacing: 12) {
            if lgtm.running {
                ProgressView().controlSize(.large)
                Text("Querying the metrics store…").font(.callout).foregroundStyle(.secondary)
                if let since = lgtm.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(elapsedNote(Int(ctx.date.timeIntervalSince(since))))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "chart.xyaxis.line").font(.largeTitle).foregroundStyle(.secondary)
                Text("\(what) needs the metrics store, which did not answer.")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = lgtm.error {
                    Text(error)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 520)
                }
                Text("The Cluster tab reads the Kubernetes API directly and still works.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Try again") { Task { await lgtm.reloadMetrics() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(shortContext)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .help(lgtm.context)

            Picker("", selection: $tab) {
                ForEach(LgtmTab.allCases) { t in
                    Label(t.title, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Spacer(minLength: 8)

            if let source = lgtm.full?.source {
                Text(source)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help("The metrics store the analysis queried")
            }

            Picker("", selection: $lgtm.window) {
                ForEach(LgtmWindow.allCases) { w in Text(w.label).tag(w) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(lgtm.running)
            .help("Lookback window for the Metrics and Findings tabs")

            if lgtm.running {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await lgtm.load() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Re-run the analysis")
            }
        }
        .padding(8)
        .background(.bar)
    }

    /// The cluster the numbers came from, always on screen. The store can live
    /// in a different cluster than the workloads, and a report labelled only by
    /// its endpoint gives no way to notice you are reading the wrong one.
    private var shortContext: String {
        lgtm.context.split(separator: "/").last.map(String.init) ?? lgtm.context
    }

    // MARK: States

    private var notInstalled: some View {
        ContentUnavailableView {
            Label("kubectl-lgtm not found", systemImage: "chart.line.downtrend.xyaxis")
        } description: {
            VStack(spacing: 8) {
                Text("The stack analysis runs in a helper binary that ships inside this app. This build does not have it.")
                Text("Rebuild with scripts/bundle.sh, or install it alongside.")
                    .font(.caption)
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Reading the stack…").font(.callout).foregroundStyle(.secondary)
            if let since = lgtm.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(elapsedNote(Int(ctx.date.timeIntervalSince(since))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// Silence past ten seconds reads as a hang, and this genuinely takes
    /// longer than that - so say what it is waiting on rather than nothing.
    private func elapsedNote(_ seconds: Int) -> String {
        switch seconds {
        case ..<8:  return "\(seconds)s"
        case ..<25: return "\(seconds)s · port-forwarding to the metrics store"
        default:    return "\(seconds)s · querying the lookback window"
        }
    }

    private func failed(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Analysis failed on \(shortContext)", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 10) {
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                Button("Try again") { Task { await lgtm.load() } }
            }
        }
    }
}

// MARK: - Findings tab

struct LgtmFindingsView: View {
    let report: LgtmReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let warning = report.warning, !warning.isEmpty {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                summary
                findings
            }
            .padding()
        }
    }

    private var summary: some View {
        let comps = report.components
        let crit = comps.filter { $0.severity == "CRIT" }.count
        let warn = comps.filter { $0.severity == "WARN" }.count
        let degraded = comps.filter { !$0.healthy }.count

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            StatCard(label: "Components", value: "\(comps.count)",
                     icon: "square.stack.3d.up", color: .accentColor)
            StatCard(label: "Critical", value: "\(crit)",
                     icon: "exclamationmark.octagon", color: crit > 0 ? .red : .secondary)
            StatCard(label: "Warnings", value: "\(warn)",
                     icon: "exclamationmark.triangle", color: warn > 0 ? .orange : .secondary)
            StatCard(label: "Not Ready", value: "\(degraded)",
                     icon: "heart.slash", color: degraded > 0 ? .red : .green)
        }
    }

    private var findings: some View {
        let flagged = report.components.filter { !$0.findings.isEmpty }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Findings",
                          trailing: flagged.isEmpty
                              ? "none - the stack is sized within tolerance"
                              : "\(flagged.reduce(0) { $0 + $1.findings.count }) across \(flagged.count) components")
            ForEach(flagged) { component in
                ForEach(component.findings) { finding in
                    FindingCard(component: component, finding: finding)
                }
            }
        }
    }
}

// MARK: - Cards


private struct FindingCard: View {
    let component: LgtmComponent
    let finding: LgtmFinding
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState
    @EnvironmentObject var nav: NavState
    @EnvironmentObject var tabs: TabStore
    @State private var expanded = false
    @State private var copied = false

    /// The desktop replacement for the shell commands a health finding used to
    /// print. "Run kubectl describe" is not an instruction a window can carry
    /// out; this drops the user on the workload's pods, where Logs and Describe
    /// already live.
    private func showPods() {
        // Namespace and section both live on the active WorkspaceTab now, and
        // the sidebar's selection binding reads `tabs.active?.view` in
        // preference to `nav.selected`. Writing only NavState would leave the
        // tab and the sidebar disagreeing, and the tab would win - the button
        // would appear to do nothing. Mirror the tab strip: write through to
        // both, since every list view still reads `store.namespaceFilter`.
        search.query = component.name
        nav.path.removeAll()
        if let id = tabs.activeID {
            tabs.setNamespace(component.namespace, for: id)
            tabs.setView(.pods, for: id)
        }
        store.namespaceFilter = component.namespace
        nav.selected = .pods
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SeverityTag(severity: finding.severity)
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title).font(.callout.weight(.medium))
                    Text("\(component.title) · \(component.namespace)/\(component.name)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(finding.confidence)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Confidence, derived from how much of the window returned data")
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
            }

            if !finding.current.isEmpty || !finding.suggested.isEmpty {
                HStack(spacing: 6) {
                    Text(finding.current).font(.caption.monospaced())
                    if !finding.suggested.isEmpty {
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Text(finding.suggested).font(.caption.monospaced().weight(.semibold))
                    }
                }
            }

            if expanded {
                Text(finding.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button { showPods() } label: {
                    Label("Show pods", systemImage: "shippingbox")
                }
                .controlSize(.small)

                ForEach(finding.evidence, id: \.expr) { e in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.expr)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Text(e.value).font(.caption.monospacedDigit())
                    }
                }

                if !finding.snippet.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("values.yaml").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button(copied ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(finding.snippet, forType: .string)
                                copied = true
                            }
                            .controlSize(.small)
                        }
                        Text(finding.snippet)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(SeverityTag.color(finding.severity))
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}


struct SeverityTag: View {
    let severity: String

    static func color(_ severity: String) -> Color {
        switch severity {
        case "CRIT": return .red
        case "WARN": return .orange
        case "INFO": return .blue
        default:     return .green
        }
    }

    var body: some View {
        Text(severity.isEmpty ? "OK" : severity)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Self.color(severity).opacity(0.18), in: Capsule())
            .foregroundStyle(Self.color(severity))
    }
}

/// Memory working set over the lookback window, already resampled by the
/// analyser. Drawn rather than charted: Swift Charts would work, but this is
/// twelve lines and the app has no other chart to justify the import.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let lo = values.min() ?? 0
            let hi = values.max() ?? 1
            let span = hi - lo
            Path { path in
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * (values.count > 1 ? Double(i) / Double(values.count - 1) : 0)
                    // A flat series has no span to normalise against; centre it
                    // rather than dividing by zero into a NaN path.
                    let norm = span > 0 ? (v - lo) / span : 0.5
                    let y = geo.size.height * (1 - norm)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor.opacity(0.7), lineWidth: 1.5)
        }
    }
}

private func formatWindow(_ seconds: Double) -> String {
    let days = Int(seconds / 86400)
    if days >= 1 { return "\(days)d" }
    return "\(Int(seconds / 3600))h"
}
