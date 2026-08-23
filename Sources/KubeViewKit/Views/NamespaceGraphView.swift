import SwiftUI
import KubeModel
import KubeClient
import KubeUI

/// Argo-CD-style topology for one namespace: chips laid out in tiers, edges
/// drawn in a single `Canvas`, pan and zoom applied once to the whole pane.
struct NamespaceGraphView: View {
    let namespace: String
    @EnvironmentObject var store: ClusterStore
    @State private var expanded: Set<String> = []

    init(namespace: String) {
        self.namespace = namespace
        #if DEBUG
        _ = ResourceGraph.selfCheckOnce
        #endif
    }

    // ponytail: rebuilt from the poll snapshot on every refresh rather than
    // precomputed in `ClusterStore.refresh()` next to `namespaceSummaries` —
    // it's O(n) over a single namespace and only runs while the disclosure is
    // open. Ceiling is a namespace with thousands of pods; the upgrade path is
    // moving it into `refresh()` with the other derived state.
    private var graph: (nodes: [GraphNode], edges: [GraphEdge]) {
        ResourceGraph.build(
            pods: store.pods.filter { $0.namespace == namespace },
            services: store.services.filter { $0.namespace == namespace },
            ingresses: store.ingresses.filter { $0.namespace == namespace },
            deployments: store.deployments.filter { $0.namespace == namespace },
            statefulSets: store.statefulSets.filter { $0.namespace == namespace },
            daemonSets: store.daemonSets.filter { $0.namespace == namespace },
            replicaSets: store.replicaSets.filter { $0.namespace == namespace },
            jobs: store.jobs.filter { $0.namespace == namespace },
            cronJobs: store.cronJobs.filter { $0.namespace == namespace },
            hpas: store.hpas.filter { $0.namespace == namespace },
            expanded: expanded
        )
    }

    var body: some View {
        let g = graph
        if g.nodes.isEmpty {
            Text("Nothing to graph in this namespace")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        } else {
            GraphPane(nodes: g.nodes, edges: g.edges, expanded: $expanded)
        }
    }
}

private struct GraphPane: View {
    let nodes: [GraphNode]
    let edges: [GraphEdge]
    @Binding var expanded: Set<String>
    @EnvironmentObject var emojis: EmojiStore

    // Pan and zoom live here, not in the parent: the parent rebuilds the graph
    // in its body, so a gesture driving parent state would re-run the builder
    // on every frame.
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var dragDelta: CGSize = .zero
    @GestureState private var zoomDelta: CGFloat = 1

    // Taller than before: every chip now carries its kind on a second line,
    // because an SF Symbol alone doesn't say "StatefulSet".
    private static let nodeW: CGFloat = 158
    private static let nodeH: CGFloat = 42
    private static let colGap: CGFloat = 62
    private static let rowGap: CGFloat = 10
    private static let pad: CGFloat = 12

    /// Edges are only legible if the relationship is: an arrow into a Pod means
    /// something different from a Service, so each relation gets its own colour
    /// and the legend spells it out.
    private static func color(_ r: EdgeRelation) -> Color {
        switch r {
        case .owns:      return .secondary
        case .selects:   return .indigo
        case .routes:    return .purple
        case .scales:    return .green
        case .collapsed: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            pane
            legend
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Text("\(nodes.count) resources, \(edges.count) links")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !expanded.isEmpty {
                Button("Collapse all") { expanded.removeAll() }
                    .buttonStyle(.link).font(.caption)
            }
            Button("Reset view") { scale = 1; offset = .zero }
                .buttonStyle(.link).font(.caption)
                .help("Back to 100%, centred")
        }
    }

    /// Only the relations actually present — a legend listing edges that aren't
    /// on screen is noise.
    private var legend: some View {
        let present = EdgeRelation.allCases.filter { r in edges.contains { $0.relation == r } }
        return HStack(spacing: 14) {
            ForEach(present, id: \.self) { r in
                HStack(spacing: 5) {
                    Capsule().fill(Self.color(r)).frame(width: 14, height: 2)
                    Text(r.legend).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    /// The graph is drawn as an *overlay* on an empty flexible box, never as a
    /// child in the layout.
    ///
    /// This matters more than it looks. `content` takes a fixed frame the size
    /// of the whole graph — a busy namespace is thousands of points tall — and
    /// `scaleEffect`/`offset` are render-time only, so they don't shrink it.
    /// `.frame(maxHeight: .infinity)` never sizes *below* its child, so that
    /// height propagated up through NavigationStack and squeezed RootView's
    /// VStack until the cluster bar was pushed off screen. Overlay content is
    /// sized by its parent and may overflow without ever reporting a size back,
    /// so the pane is now exactly as big as the space it was given.
    private var pane: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
            .overlay {
                content
                    .frame(width: size.width, height: size.height)
                    // Centre-anchored so zoom grows from the middle of what
                    // you're looking at, and offset .zero means centred.
                    .scaleEffect(scale * zoomDelta, anchor: .center)
                    .offset(x: offset.width + dragDelta.width,
                            y: offset.height + dragDelta.height)
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .gesture(pan.simultaneously(with: zoom))
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                var points: [String: CGPoint] = [:]
                for n in nodes { points[n.uid] = center(n) }
                for e in edges {
                    guard let a = points[e.from], let b = points[e.to] else { continue }
                    let start = CGPoint(x: a.x + Self.nodeW / 2, y: a.y)
                    let end = CGPoint(x: b.x - Self.nodeW / 2, y: b.y)
                    let bend = max((end.x - start.x) * 0.45, 14)
                    var path = Path()
                    path.move(to: start)
                    path.addCurve(to: end,
                                  control1: CGPoint(x: start.x + bend, y: start.y),
                                  control2: CGPoint(x: end.x - bend, y: end.y))
                    ctx.stroke(path, with: .color(Self.color(e.relation).opacity(0.55)), lineWidth: 1.2)

                    // The verb, printed on the gap between the two columns.
                    // ponytail: drawn on every edge, not deduplicated — at a
                    // few hundred edges Canvas text is cheap. If it ever isn't,
                    // drop the label below some zoom threshold.
                    let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 7)
                    var text = ctx.resolve(
                        Text(e.relation.label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Self.color(e.relation))
                    )
                    text.shading = .color(Self.color(e.relation).opacity(0.85))
                    let sz = text.measure(in: CGSize(width: Self.colGap, height: 20))
                    // Blank the curve behind the word so the two don't collide.
                    ctx.fill(Path(roundedRect: CGRect(x: mid.x - sz.width / 2 - 2,
                                                      y: mid.y - sz.height / 2,
                                                      width: sz.width + 4,
                                                      height: sz.height),
                                  cornerRadius: 2),
                             with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.9)))
                    ctx.draw(text, at: mid, anchor: .center)
                }
            }
            .frame(width: size.width, height: size.height)
            ForEach(nodes) { node in
                nodeView(node).position(center(node))
            }
        }
    }

    private var pan: some Gesture {
        DragGesture()
            .updating($dragDelta) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .updating($zoomDelta) { value, state, _ in state = value.magnification }
            .onEnded { value in scale = min(max(scale * value.magnification, 0.35), 2.5) }
    }

    private var size: CGSize {
        let cols = CGFloat((nodes.map(\.column).max() ?? 0) + 1)
        let rows = CGFloat((nodes.map(\.row).max() ?? 0) + 1)
        return CGSize(width: cols * (Self.nodeW + Self.colGap) - Self.colGap + Self.pad * 2,
                      height: rows * (Self.nodeH + Self.rowGap) - Self.rowGap + Self.pad * 2)
    }

    private func center(_ node: GraphNode) -> CGPoint {
        CGPoint(x: Self.pad + CGFloat(node.column) * (Self.nodeW + Self.colGap) + Self.nodeW / 2,
                y: Self.pad + CGFloat(node.row) * (Self.nodeH + Self.rowGap) + Self.nodeH / 2)
    }

    @ViewBuilder
    private func nodeView(_ node: GraphNode) -> some View {
        if node.isAggregate {
            Button { expanded.insert(node.collapsesOwner ?? "") } label: { chip(node) }
                .buttonStyle(.plain)
                .help("Show the remaining \(node.collapsedCount) pods")
        } else if node.kind == .pod, let ns = node.ref.namespace {
            NavigationLink(value: AppRoute.pod(PodRoute(namespace: ns, name: node.ref.resourceName))) {
                chip(node)
            }
            .buttonStyle(.plain)
        } else {
            chip(node)
        }
    }

    // ponytail: a chip, not `ResourceCard`. The card's hover state, emoji
    // TextField and describe sheet cost far too much at a couple of hundred
    // instances; the emoji still renders, right-click describe doesn't.
    private func chip(_ node: GraphNode) -> some View {
        HStack(spacing: 6) {
            if let emoji = emojis.emoji(for: node.ref) {
                Text(emoji).font(.system(size: 12))
            } else {
                Image(systemName: node.kind.icon)
                    .font(.system(size: 11)).foregroundStyle(node.kind.accent)
                    .frame(width: 13)
            }
            VStack(alignment: .leading, spacing: 0) {
                // The kind, spelled out. An SF Symbol distinguishes a Pod from a
                // Service only if you already know both symbols.
                Text(node.isAggregate ? "Pods" : node.kind.title)
                    .font(.system(size: 8, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.4)
                    .foregroundStyle(node.kind.accent)
                    .lineLimit(1)
                Text(node.label)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 1) {
                Circle()
                    .fill(node.healthy ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(node.detail)
                    .font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .frame(width: Self.nodeW, height: Self.nodeH)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(node.kind.accent.opacity(node.healthy ? 0.45 : 0.9),
                              lineWidth: node.healthy ? 1 : 1.5)
        )
        .help("\(node.kind.title) \(node.label) — \(node.detail)")
    }
}
