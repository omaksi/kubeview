import SwiftUI

/// Draws one product's data path: nodes laid out left to right along the flow,
/// coloured by how loaded they are, so a bottleneck reads as a hot node with
/// everything downstream of it idle.
struct LgtmGraphView: View {
    let product: String
    let nodes: [LgtmGraphNode]
    let edges: [LgtmFlowEdge]
    /// Called with a node id when the user picks one.
    var onSelect: ((String) -> Void)?

    // Wide enough for the longest role label ("overrides-exporter",
    // "single-binary") without truncating on the common case; tall enough
    // for label + lane + detail, matching NamespaceGraphView's three-line
    // chip shape at a slightly larger size - this graph tops out around 15
    // nodes for Mimir, not the hundreds a namespace can have, so there's
    // room to spend.
    fileprivate static let nodeW: CGFloat = 180
    fileprivate static let nodeH: CGFloat = 64
    private static let colGap: CGFloat = 60
    private static let rowGap: CGFloat = 12
    private static let pad: CGFloat = 14

    private var placed: [(node: LgtmGraphNode, column: Int, row: Int)] {
        LgtmGraphLayout.place(nodes: nodes, edges: edges)
    }

    var body: some View {
        if nodes.isEmpty {
            Text("No \(product) components to graph")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                legend
                ScrollView([.horizontal, .vertical]) {
                    canvasContent.padding(Self.pad)
                }
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 14) {
            Text("\(nodes.count) components, \(edges.count) links")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            levelDot(.ok, "ok")
            levelDot(.warn, "warn")
            levelDot(.critical, "critical")
            if nodes.contains(where: { !$0.present }) {
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.diamond.fill")
                        .font(.system(size: 8)).foregroundStyle(.orange)
                    Text("not deployed").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        // This is a map, not a verdict: colour here reflects observed events
        // on the node (not ready, crashlooping, OOMKilled, over a limit,
        // throttling recorded) - the two calling tabs populate `level` only
        // from those, never from a saturation cutoff this view invents.
        .help("Colour reflects observed events, not a saturation threshold")
    }

    private func levelDot(_ level: LgtmNodeLevel, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(Self.color(level)).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    fileprivate static func color(_ level: LgtmNodeLevel) -> Color {
        switch level {
        case .unknown:  return .secondary
        case .ok:       return .green
        case .warn:     return .orange
        case .critical: return .red
        }
    }

    // MARK: - Canvas

    private func canvasSize(_ placed: [(node: LgtmGraphNode, column: Int, row: Int)]) -> CGSize {
        let cols = CGFloat((placed.map(\.column).max() ?? 0) + 1)
        let rows = CGFloat((placed.map(\.row).max() ?? 0) + 1)
        return CGSize(width: cols * (Self.nodeW + Self.colGap) - Self.colGap,
                      height: rows * (Self.nodeH + Self.rowGap) - Self.rowGap)
    }

    private func point(_ column: Int, _ row: Int) -> CGPoint {
        CGPoint(x: CGFloat(column) * (Self.nodeW + Self.colGap) + Self.nodeW / 2,
                y: CGFloat(row) * (Self.nodeH + Self.rowGap) + Self.nodeH / 2)
    }

    /// The graph is a fixed-size `Canvas` + positioned chips inside a
    /// `ScrollView`, not the pan/zoom container `NamespaceGraphView` uses.
    /// That custom gesture handling earns its keep there because a busy
    /// namespace can be thousands of points tall; this graph tops out
    /// around 15-20 nodes (Mimir, the largest product) and fits or scrolls
    /// like any other content - a second gesture-driven pan/zoom
    /// implementation would be solving a problem this view doesn't have.
    private var canvasContent: some View {
        let laid = placed
        let size = canvasSize(laid)
        var points: [String: CGPoint] = [:]
        for p in laid { points[p.node.id] = point(p.column, p.row) }
        let w = max(size.width, Self.nodeW)
        let h = max(size.height, Self.nodeH)

        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for e in edges {
                    guard let a = points[e.from], let b = points[e.to] else { continue }
                    drawEdge(&ctx, from: a, to: b, verb: e.verb)
                }
            }
            .frame(width: w, height: h)
            ForEach(laid, id: \.node.id) { p in
                let n = p.node
                Chip(node: n, onTap: onSelect.map { callback in { callback(n.id) } })
                    .position(points[n.id] ?? CGPoint(x: Self.nodeW / 2, y: Self.nodeH / 2))
            }
        }
        .frame(width: w, height: h)
    }

    /// Curve + arrowhead + verb label. Mirrors the technique
    /// `NamespaceGraphView` uses for its own Canvas edges (resolved `Text`
    /// with `.shading` set explicitly, not `.foregroundStyle` on the
    /// `Text` itself, which Canvas's `resolve` doesn't carry through) -
    /// same problem, same proven fix, written fresh here since that file is
    /// out of this lane.
    private func drawEdge(_ ctx: inout GraphicsContext, from start0: CGPoint, to end0: CGPoint, verb: String) {
        let start = CGPoint(x: start0.x + Self.nodeW / 2, y: start0.y)
        let end = CGPoint(x: end0.x - Self.nodeW / 2, y: end0.y)
        let bend = max((end.x - start.x) * 0.45, 14)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end,
                      control1: CGPoint(x: start.x + bend, y: start.y),
                      control2: CGPoint(x: end.x - bend, y: end.y))
        ctx.stroke(path, with: .color(Color.secondary.opacity(0.5)), lineWidth: 1.2)

        // Arrowhead aimed along the straight start->end vector rather than
        // the curve's true end tangent - close enough at this node spacing
        // and avoids deriving the bezier tangent. Guards the one division
        // here: two node centres landing on the same point (a zero-length
        // edge, e.g. a bad edge table pointing a node at itself) would
        // otherwise normalise a zero vector into NaN, which Path renders as
        // nothing - silently losing the arrow rather than crashing, but
        // worth guarding explicitly rather than relying on that.
        let dx = end.x - start.x, dy = end.y - start.y
        let len = (dx * dx + dy * dy).squareRoot()
        if len > 0 {
            let ux = dx / len, uy = dy / len
            let size: CGFloat = 6
            let backX = end.x - ux * size, backY = end.y - uy * size
            let px = -uy, py = ux
            var arrow = Path()
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(x: backX + px * size * 0.45, y: backY + py * size * 0.45))
            arrow.addLine(to: CGPoint(x: backX - px * size * 0.45, y: backY - py * size * 0.45))
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(Color.secondary.opacity(0.8)))
        }

        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 7)
        var text = ctx.resolve(Text(verb).font(.system(size: 8, weight: .medium)))
        text.shading = .color(.secondary)
        let measured = text.measure(in: CGSize(width: Self.colGap + 20, height: 20))
        ctx.fill(Path(roundedRect: CGRect(x: mid.x - measured.width / 2 - 2, y: mid.y - measured.height / 2,
                                          width: measured.width + 4, height: measured.height),
                      cornerRadius: 2),
                 with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.9)))
        ctx.draw(text, at: mid, anchor: .center)
    }
}

// MARK: - Layout

/// Pure tiering over an arbitrary node/edge list - no SwiftUI, so it can be
/// exercised directly the way `ResourceGraph`'s layout is. Column is
/// longest-path-from-source via Kahn's algorithm rather than
/// `ResourceGraph`'s static kind-based column table: `ResourceGraph.column`
/// works because `ResourceKind` gives it a fixed small vocabulary to switch
/// on, but a logical role node carries no `ResourceKind` (forcing one would
/// mean inventing a fake kind per LGTM role, worse than writing the ~20
/// lines below), and this file already has the real edges in hand, which
/// make longest-path tiering both correct and cheap at this node count.
enum LgtmGraphLayout {
    /// Keeps the hot path (write, then read) together at the front of each
    /// column and pushes caches/maintenance to the back - the ordering the
    /// brief asks for, applied as the primary row-sort key.
    static let lanePriority: [LgtmLane: Int] = [.write: 0, .read: 1, .standalone: 2, .maintenance: 3, .cache: 4]

    static func place(nodes: [LgtmGraphNode], edges: [LgtmFlowEdge]) -> [(node: LgtmGraphNode, column: Int, row: Int)] {
        guard !nodes.isEmpty else { return [] }
        let ids = Set(nodes.map(\.id))
        // Self-loops and edges pointing at an id not in `nodes` are dropped
        // up front - a self-loop can't be laid out meaningfully, and a
        // dangling reference would otherwise need every lookup below to
        // guard it individually.
        let liveEdges = edges.filter { ids.contains($0.from) && ids.contains($0.to) && $0.from != $0.to }

        var outgoing: [String: [String]] = [:]
        var indegree: [String: Int] = [:]
        for n in nodes { indegree[n.id] = 0 }
        for e in liveEdges {
            outgoing[e.from, default: []].append(e.to)
            indegree[e.to, default: 0] += 1
        }

        let touched = Set(liveEdges.flatMap { [$0.from, $0.to] })
        let isolated = nodes.filter { !touched.contains($0.id) }
        let connected = nodes.filter { touched.contains($0.id) }

        var column: [String: Int] = [:]
        var queue = connected.filter { (indegree[$0.id] ?? 0) == 0 }.map(\.id)
        var head = 0
        for id in queue { column[id] = 0 }
        while head < queue.count {
            let id = queue[head]; head += 1
            let c = column[id] ?? 0
            for next in outgoing[id] ?? [] {
                indegree[next, default: 0] -= 1
                column[next] = max(column[next] ?? 0, c + 1)
                if indegree[next] == 0 { queue.append(next) }
            }
        }
        // Anything left has indegree > 0 forever - it's on a cycle. The real
        // topologies never are (see `LgtmTopology.selfCheck`), but a bad
        // edge table reaching this code must render, not hang: park
        // whatever's left after the furthest column Kahn's algorithm
        // actually resolved, one pass, no recursion back into the cycle.
        let resolvedMax = column.values.max() ?? 0
        for n in connected where column[n.id] == nil {
            column[n.id] = resolvedMax + 1
        }
        // Nodes with no edges at all get their own placement rule: if
        // *nothing* has edges (an unknown product, or a caller-supplied
        // product this table has no entry for), spread them by lane so the
        // graph still shows structure instead of one indistinguishable
        // stack. If only *some* nodes are edge-free (e.g. Mimir's
        // overrides-exporter, which genuinely has none), shelve them
        // together after the real flow instead of crowding column 0 next to
        // genuine sources.
        if !isolated.isEmpty {
            if connected.isEmpty {
                for n in isolated { column[n.id] = lanePriority[n.lane] ?? 2 }
            } else {
                let shelf = (column.values.max() ?? -1) + 1
                for n in isolated { column[n.id] = shelf }
            }
        }

        // Rows: lane first (keeps write/read together, pushes cache/
        // maintenance aside), then barycenter of already-placed parents -
        // the same idea as `ResourceGraph.layout`'s pass, reimplemented
        // rather than shared since it operates on `GraphNode`/`GraphEdge`,
        // then id for a total, deterministic order.
        var parents: [String: [String]] = [:]
        for e in liveEdges { parents[e.to, default: []].append(e.from) }
        var row: [String: Int] = [:]
        let maxColumn = column.values.max() ?? 0
        for c in 0...maxColumn {
            let inColumn = nodes.filter { column[$0.id] == c }
            let ordered = inColumn.sorted { a, b in
                let la = lanePriority[a.lane] ?? 9, lb = lanePriority[b.lane] ?? 9
                if la != lb { return la < lb }
                let ba = barycenter(a.id, parents, row), bb = barycenter(b.id, parents, row)
                if ba != bb { return ba < bb }
                return a.id < b.id
            }
            for (r, n) in ordered.enumerated() { row[n.id] = r }
        }

        return nodes.map { (node: $0, column: column[$0.id] ?? 0, row: row[$0.id] ?? 0) }
    }

    private static func barycenter(_ id: String, _ parents: [String: [String]], _ row: [String: Int]) -> Double {
        let rows = (parents[id] ?? []).compactMap { row[$0] }
        guard !rows.isEmpty else { return .greatestFiniteMagnitude }
        return Double(rows.reduce(0, +)) / Double(rows.count)
    }
}

// MARK: - Chip

private struct Chip: View {
    let node: LgtmGraphNode
    let onTap: (() -> Void)?

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var levelColor: Color { LgtmGraphView.color(node.level) }

    /// Clamped to 0...1 for GEOMETRY ONLY - this is the one place `saturation`
    /// is allowed to lose precision, because a `frame(width:)` past the
    /// chip's own bounds would break layout, not because the underlying
    /// number is somehow wrong above 1.0. Never read this for display text;
    /// see `saturationText`, which reads `node.saturation` directly.
    private var fillFraction: CGFloat {
        guard let s = node.saturation, s.isFinite else { return 0 }
        return CGFloat(min(max(s, 0), 1))
    }

    /// The raw measurement, unclamped - "198%" is a real, legitimate answer
    /// this tab must be able to show (a component over its limit, or
    /// measured against a request with no limit set). Reads `node.saturation`
    /// directly rather than `fillFraction`: the fill bar and the number it
    /// sits next to must never disagree about what was actually measured,
    /// only about how far a bar can physically be drawn.
    private var saturationText: String? {
        guard node.present, let s = node.saturation, s.isFinite else { return nil }
        return "\(Int((max(s, 0) * 100).rounded()))%"
    }

    /// Same clamp-and-guard as `fillFraction`, for the busiest-replica mark -
    /// a drawing position only, never read for text. Independent of
    /// `saturation`/`fillFraction` on purpose - the two can disagree (that
    /// disagreement *is* the signal) and each is guarded on its own so one
    /// being absent or non-finite never hides the other.
    private var peakFraction: CGFloat? {
        guard node.present, let p = node.peakReplicaSaturation, p.isFinite else { return nil }
        return CGFloat(min(max(p, 0), 1))
    }

    /// True when the busiest replica is over 100% - the mark must render
    /// differently in this case (see `content`), or a peak of exactly 100%
    /// and a peak of 198% both draw as a tick sitting on the same edge,
    /// which is the same information loss `saturationText` exists to avoid,
    /// just moved into the bar instead of the label.
    private var peakOverflow: Bool {
        guard let p = node.peakReplicaSaturation, p.isFinite else { return false }
        return p > 1
    }

    /// What the tooltip says for a present node - `node.detail`, plus the
    /// exact (unclamped) peak reading when there is one to report.
    private var presentHelpText: String {
        guard let p = node.peakReplicaSaturation, p.isFinite else {
            return "\(node.label) - \(node.detail)"
        }
        let pct = Int((max(p, 0) * 100).rounded())
        return "\(node.label) - \(node.detail) · busiest replica \(pct)%"
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if node.present {
                    Circle().fill(levelColor).frame(width: 6, height: 6)
                } else {
                    // A gap in the data path is information the user asked to
                    // see, not a disabled control - its own icon and colour,
                    // not the level vocabulary (orange here means "notice
                    // this hop", not "warn-level event observed").
                    Image(systemName: "questionmark.diamond.fill")
                        .font(.system(size: 7)).foregroundStyle(.orange)
                }
                Text(node.label)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let saturationText {
                    Text(saturationText)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(levelColor)
                }
            }
            Text(node.lane.rawValue)
                .font(.system(size: 8, weight: .medium))
                .textCase(.uppercase)
                .kerning(0.4)
                .foregroundStyle(.secondary)
            Text(node.present ? node.detail : "not deployed")
                .font(.caption2)
                .fontWeight(node.present ? .regular : .semibold)
                .foregroundStyle(node.present ? Color.secondary : Color.orange)
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: LgtmGraphView.nodeW, height: LgtmGraphView.nodeH, alignment: .leading)
        .background(
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                    // Saturation as a horizontal fill under the text, the
                    // same idea `HeadroomBar` uses for a usage bar: a
                    // bottleneck reads as a chip that's mostly coloured in,
                    // with idle nodes downstream staying mostly empty. Width
                    // is `fillFraction` directly - a straight-line read of
                    // the measurement, never bucketed into a handful of
                    // fixed levels.
                    if node.present, fillFraction > 0 {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(levelColor.opacity(0.28))
                            .frame(width: geo.size.width * fillFraction)
                    }
                    // The busiest-replica mark. Plain foreground, not the
                    // level colour and not red/orange - it is the top of a
                    // range ("typical is the fill, busiest is this line"),
                    // not a second verdict stacked on top of the first one.
                    // `peakFraction` is clamped for the draw position (layout
                    // must never see an unclamped value), but a clamped tick
                    // sitting exactly on the edge would be indistinguishable
                    // from a genuine peak of 100% - `peakOverflow` swaps it
                    // for a chevron pointing off the edge instead, so "goes
                    // further than the bar can show" still reads as
                    // different from "stops right here". The exact figure
                    // stays in the tooltip either way.
                    if let peakFraction {
                        if peakOverflow {
                            Image(systemName: "chevron.compact.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.primary.opacity(0.55))
                                .position(x: geo.size.width - 5, y: geo.size.height / 2)
                        } else {
                            Rectangle()
                                .fill(Color.primary.opacity(0.45))
                                .frame(width: 1.5, height: geo.size.height)
                                .offset(x: geo.size.width * peakFraction - 0.75)
                        }
                    }
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(node.present ? levelColor.opacity(0.55) : Color.orange.opacity(0.8),
                              style: StrokeStyle(lineWidth: node.present ? 1.3 : 1.6, dash: node.present ? [] : [4, 3]))
        )
        // No opacity dimming for an absent node. A missing hop in the data
        // path is exactly the kind of thing "an accurate map" exists to
        // show - fading it toward invisible would read as "unavailable
        // control", the opposite of what a gap here is meant to say.
        .contentShape(Rectangle())
        .help(node.present
              ? presentHelpText
              : "\(node.label) - expected by the topology but not present in this cluster")
    }
}

// MARK: - Self-check

#if DEBUG
/// Covers the two properties that matter for a GUI, not just correctness:
/// the tiering never hangs (the whole point of testing a cycle), and every
/// node - including one with no edges at all, or a totally empty product -
/// still gets placed somewhere rather than silently dropped or crashing.
extension LgtmGraphLayout {
    static func selfCheck() {
        func node(_ id: String, lane: LgtmLane = .standalone) -> LgtmGraphNode {
            LgtmGraphNode(id: id, label: id, detail: "", lane: lane, level: .unknown, saturation: nil, present: true)
        }

        assert(place(nodes: [], edges: []).isEmpty, "zero nodes must not crash")
        assert(place(nodes: [node("a")], edges: []).count == 1, "a single node must place cleanly")

        let chain = place(nodes: [node("a"), node("b"), node("c")],
                          edges: [LgtmFlowEdge(from: "a", to: "b", verb: "x"),
                                  LgtmFlowEdge(from: "b", to: "c", verb: "x")])
        func col(_ id: String) -> Int { chain.first { $0.node.id == id }!.column }
        assert(col("a") < col("b") && col("b") < col("c"), "a straight chain must strictly increase in column")

        // The safety property this whole function exists for: a cycle must
        // terminate, and must still place both nodes rather than dropping
        // whichever one Kahn's algorithm never reaches indegree 0 on.
        let cyclic = place(nodes: [node("x"), node("y")],
                           edges: [LgtmFlowEdge(from: "x", to: "y", verb: "x"),
                                   LgtmFlowEdge(from: "y", to: "x", verb: "x")])
        assert(cyclic.count == 2, "a cycle must still place every node, not hang or drop one")

        // A self-loop is dropped as live-edge input, so a node whose only
        // edge points at itself is isolated, not stuck.
        let selfLoop = place(nodes: [node("s")], edges: [LgtmFlowEdge(from: "s", to: "s", verb: "x")])
        assert(selfLoop.count == 1)

        let noEdges = place(nodes: [node("w", lane: .write), node("r", lane: .read)], edges: [])
        assert(Set(noEdges.map(\.column)).count == 2, "with zero edges, lane fallback must still separate write from read")

        // A node with no edges at all, alongside a real chain, must not sit
        // in column 0 next to genuine sources.
        let mixed = place(nodes: [node("a"), node("b"), node("iso")],
                          edges: [LgtmFlowEdge(from: "a", to: "b", verb: "x")])
        let isoColumn = mixed.first { $0.node.id == "iso" }!.column
        let bColumn = mixed.first { $0.node.id == "b" }!.column
        assert(isoColumn > bColumn, "an edge-free node must shelve after the real flow, not crowd its front")
    }
}
#endif
