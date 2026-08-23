import SwiftUI
import KubeModel
import KubeClient
import KubeUI

/// The tab strip. Each tab shows its cluster, its namespace and one status dot
/// that carries the whole lifecycle:
///
///   filled green   fetching — this is the focused tab, the only one polling
///   hollow green   reachable, idle — probe succeeds, nothing being fetched
///   amber ring     reachable but credentials rejected
///   filled red     unreachable
///   dashed grey    restored from a previous launch, not contacted yet
///
/// Filled means "costing you kubectl calls", hollow means "one probe a minute".
/// That distinction is the point of the whole design, so it gets the strongest
/// visual difference available at 7pt.
struct TabStrip: View {
    @EnvironmentObject var tabs: TabStore
    @EnvironmentObject var manager: ClusterManager
    @EnvironmentObject var names: ClusterNameStore

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs.tabs) { tab in
                        // `applyCadence` guarantees a store for every open tab,
                        // so this is never nil in practice — but skipping beats
                        // force-unwrapping on a path that runs at every launch.
                        if let store = manager.stores[tab.context] {
                            TabChip(tab: tab, isActive: tab.id == tabs.activeID, store: store)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            // Same stale-NSScrollView trap the cluster bar hit: the strip is
            // rebuilt when tabs change, and without a key SwiftUI reuses a
            // scroll view sized before they arrived.
            .id(tabs.tabs.map(\.id))

            Button {
                openTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("New tab (⌘T)")
            .padding(.trailing, 6)
        }
        .frame(height: 32)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func openTab() {
        guard let seed = tabs.active?.context ?? manager.availableContexts.first else { return }
        tabs.open(context: seed)
        manager.applyCadence(openContexts: tabs.openContexts, live: tabs.active?.context)
    }
}

private struct TabChip: View {
    let tab: WorkspaceTab
    let isActive: Bool
    @ObservedObject var store: ClusterStore
    @EnvironmentObject var tabs: TabStore
    @EnvironmentObject var manager: ClusterManager
    @EnvironmentObject var names: ClusterNameStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(state: state)
            VStack(alignment: .leading, spacing: 0) {
                Text(names.name(for: tab.context))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                Text(tab.subtitle)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Only the active or hovered tab offers a close button — a row of
            // permanent ✕ glyphs reads as clutter at this size.
            if (isActive || hovering) && tabs.tabs.count > 1 {
                Button {
                    tabs.close(tab.id)
                    manager.applyCadence(openContexts: tabs.openContexts, live: tabs.active?.context)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .frame(width: 13, height: 13)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close tab (⌘W)")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(width: 176, height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator, lineWidth: isActive ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            tabs.focus(tab.id)
            manager.applyCadence(openContexts: tabs.openContexts, live: tab.context)
        }
        .help("\(tab.context) · \(tab.subtitle)\n\(state.explanation)")
    }

    private var state: TabState {
        if let fault = store.fault {
            return fault == .notLoggedIn ? .unauthorized : .unreachable
        }
        switch store.cadence {
        case .live:       return store.hasData ? .fetching : .connecting
        case .background: return store.lastProbe == nil ? .uncontacted : .reachable
        case .idle:       return .uncontacted
        }
    }
}

enum TabState {
    case uncontacted, connecting, reachable, fetching, unauthorized, unreachable

    var explanation: String {
        switch self {
        case .uncontacted:  return "Not contacted yet"
        case .connecting:   return "Connecting…"
        case .reachable:    return "Reachable — not fetching"
        case .fetching:     return "Fetching now"
        case .unauthorized: return "Credentials expired"
        case .unreachable:  return "Unreachable"
        }
    }
}

/// 7pt of status. Fill means data is moving; an outline means it isn't.
struct StatusDot: View {
    let state: TabState
    private let size: CGFloat = 7

    var body: some View {
        Group {
            switch state {
            case .fetching:
                Circle().fill(.green)
            case .reachable:
                Circle().strokeBorder(.green, lineWidth: 1.5)
            case .unauthorized:
                Circle().strokeBorder(.orange, lineWidth: 1.5)
                    .background(Circle().fill(.orange).padding(1.5))
            case .unreachable:
                Circle().fill(.red)
            case .connecting:
                Circle().strokeBorder(.blue, lineWidth: 1.5).opacity(0.6)
            case .uncontacted:
                Circle().strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))
            }
        }
        .frame(width: size, height: size)
    }
}

/// ⌘T / ⌘W / ⌃⇥ / ⌘1–9, all conventional. Nothing here is invented — tab
/// switching already has a keyboard vocabulary and users arrive knowing it.
///
/// Every command re-applies cadence, because each one changes either which tab
/// is focused or which contexts are open.
struct TabCommands: Commands {
    @ObservedObject var tabs: TabStore
    @ObservedObject var manager: ClusterManager

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                guard let seed = tabs.active?.context ?? manager.availableContexts.first else { return }
                tabs.open(context: seed)
                sync()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("Close Tab") {
                guard let id = tabs.activeID else { return }
                tabs.close(id)
                sync()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(tabs.tabs.count <= 1)

            Button("Reopen Closed Tab") {
                tabs.reopenClosed()
                sync()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Divider()

            Button("Next Tab") { tabs.focusNext(by: 1); sync() }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { tabs.focusNext(by: -1); sync() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

            // ⌘1–9 by position. Nine is the convention's limit, not ours.
            ForEach(1...9, id: \.self) { n in
                Button("Tab \(n)") { tabs.focus(index: n - 1); sync() }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                    .disabled(tabs.tabs.count < n)
            }
        }
    }

    private func sync() {
        manager.applyCadence(openContexts: tabs.openContexts, live: tabs.active?.context)
    }
}

/// Cluster ▸ namespace for the focused tab, plus search. Replaces the pill
/// strip: the tab already names the context, so this row exists only to
/// *change* it.
struct ContextBar: View {
    @EnvironmentObject var tabs: TabStore
    @EnvironmentObject var manager: ClusterManager
    @EnvironmentObject var names: ClusterNameStore
    @ObservedObject var store: ClusterStore

    var body: some View {
        HStack(spacing: 7) {
            Picker("Cluster", selection: clusterBinding) {
                ForEach(manager.availableContexts, id: \.self) { ctx in
                    Text(names.name(for: ctx)).tag(ctx)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("This tab's cluster")

            Image(systemName: "chevron.right")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)

            Picker("Namespace", selection: namespaceBinding) {
                Text("All Namespaces").tag(String?.none)
                ForEach(ClusterStore.pickerOptions(store.namespaces.map(\.name),
                                                   selected: tabs.active?.namespace), id: \.self) { ns in
                    Text(ns).tag(String?.some(ns))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("This tab's namespace")

            Spacer()
            GlobalSearchBar().frame(width: 240)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var clusterBinding: Binding<String> {
        Binding(
            get: { tabs.active?.context ?? "" },
            set: { newContext in
                guard let id = tabs.activeID else { return }
                tabs.setContext(newContext, for: id)
                // A different cluster is a different connection, so this goes
                // through the same path as focusing the tab — including landing
                // on the expired-credentials state if that's what it returns.
                manager.applyCadence(openContexts: tabs.openContexts, live: newContext)
            }
        )
    }

    /// Namespace is a filter on a connection we already have, so it never
    /// re-applies cadence. It writes through to the store because every list
    /// view reads `store.namespaceFilter`.
    private var namespaceBinding: Binding<String?> {
        Binding(
            get: { tabs.active?.namespace },
            set: { ns in
                guard let id = tabs.activeID else { return }
                tabs.setNamespace(ns, for: id)
                store.namespaceFilter = ns
            }
        )
    }
}
