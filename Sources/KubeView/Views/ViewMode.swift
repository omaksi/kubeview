import SwiftUI

enum ViewMode: String, CaseIterable {
    case cards, table
    var icon: String {
        switch self {
        case .cards: return "square.grid.2x2"
        case .table: return "list.bullet"
        }
    }
}

struct ViewModeToggle: View {
    @Binding var mode: ViewMode
    var body: some View {
        Picker("View", selection: $mode) {
            ForEach(ViewMode.allCases, id: \.self) { m in
                Image(systemName: m.icon).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Toggle cards / table")
    }
}

/// Per-view header: count + optional trailing (usually the view-mode toggle).
/// The search field itself lives at the top of the window (`GlobalSearchBar`)
/// and drives every view through the app's global search state.
struct ViewHeader<Trailing: View>: View {
    let count: Int
    let label: String
    let trailing: Trailing

    init(count: Int, label: String = "items", @ViewBuilder trailing: () -> Trailing) {
        self.count = count
        self.label = label
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Spacer()
            trailing
            Text("\(count) \(label)").foregroundStyle(.secondary).font(.caption)
        }
        .padding(8)
        .background(.bar)
    }
}

/// Centered "Loading…" placeholder shown in place of an empty list/grid on
/// the very first refresh, before any data has arrived. Gate usage on
/// `store.isFirstLoad` (plus an emptiness check, so a partial refresh still
/// shows what it got) — never on `lastRefresh` alone, or a failed first
/// refresh spins forever. Pass the store's `activity`/`activitySince` through
/// explicitly so the "still working" chatter below keeps working.
struct LoadingPlaceholder: View {
    let label: String
    var activity: String? = nil
    var activitySince: Date? = nil

    /// Below this, extra chatter is noise — a normal first load resolves well
    /// inside it. Past it, silence reads as a hang, so say what we're waiting on.
    private let chattyAfter: TimeInterval = 2

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Loading \(label)…")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let since = activitySince {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let elapsed = ctx.date.timeIntervalSince(since)
                    if elapsed >= chattyAfter {
                        VStack(spacing: 6) {
                            Text("\(activity ?? "Working")… \(Int(elapsed))s")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if elapsed >= 8 {
                                Text("Taking longer than usual. Sidebar → Diagnostics shows every kubectl call.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Refresh-failure strip. Mounted once in `ClusterContentView` so it covers
/// every view — list views have no error surface of their own, and the
/// Overview banner it replaces was unreachable on a failed first refresh.
struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
            Text(message)
                .font(.caption.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("Retry", action: retry)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

