import SwiftUI
import KubeModel
import KubeClient
import KubeUI

/// Draws the whole LGTM stack as ONE top-to-bottom graph: every product's
/// components in a single tiered flow, so the cross-product hops
/// `LgtmTopology` already models - Alloy feeding all three ingest paths,
/// Grafana reading all three query paths - are edges on the page instead of
/// something the reader has to hold in their head across five separate
/// pictures. Five per-product graphs could only ever draw each of those
/// seams twice, as a stub at each end.
///
/// Vertical rather than left-to-right because the merged graph is long: nine
/// tiers deep and seven nodes wide on the reference 30-component stack, which
/// is a shape a window scrolls comfortably downwards and awkwardly sideways.
/// `LgtmGraphLayout.place` returns `(node, tier, slot)`; this view maps tier
/// to y and slot to x.
///
/// Product is a hue, load is the fill. The two vocabularies are deliberately
/// disjoint (see `productColor`), so in the one view that shows both at once
/// a colour can never be read as a verdict.
struct LgtmGraphView: View {
    let nodes: [LgtmGraphNode]
    let edges: [LgtmFlowEdge]
    /// Called with a node id when the user picks one.
    var onSelect: ((String) -> Void)?

    // Wide enough for the longest role label ("overrides-exporter",
    // "alloy-singleton") without truncating on the common case; tall enough
    // for label + product/lane + detail + the pod pip row.
    fileprivate static let nodeW: CGFloat = 180
    fileprivate static let nodeH: CGFloat = 92
    // Vertical flow: `tierGap` is the down-the-page gap between tiers,
    // `slotGap` the sideways gap between siblings sharing one.
    private static let tierGap: CGFloat = 54
    private static let slotGap: CGFloat = 22
    private static let pad: CGFloat = 14

    private var placed: [(node: LgtmGraphNode, tier: Int, slot: Int)] {
        LgtmGraphLayout.place(nodes: nodes, edges: edges)
    }

    var body: some View {
        if nodes.isEmpty {
            Text("No components to graph")
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

    /// Products in `LgtmTopology.known` order, then anything else the report
    /// classified that this table has no entry for, so an unrecognised
    /// product still gets a swatch rather than silently sharing the fallback
    /// grey with nothing to explain it.
    private var productsInGraph: [String] {
        let present = Set(nodes.map(\.product)).filter { !$0.isEmpty }
        let ordered = LgtmTopology.known.filter(present.contains)
        return ordered + present.subtracting(ordered).sorted()
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            HStack(spacing: 12) {
                ForEach(productsInGraph, id: \.self) { product in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.productColor(product))
                            .frame(width: 10, height: 8)
                        Text(product).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if nodes.contains(where: { !$0.pods.isEmpty }) {
                    Text("one mark per pod").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        // This is a map, not a verdict: level colour here reflects observed
        // events on the node (not ready, crashlooping, OOMKilled, over a
        // limit, throttling recorded) - the two calling tabs populate `level`
        // only from those, never from a saturation cutoff this view invents.
        // Product hue says which product a node belongs to and nothing else.
        .help("Hue is which product; level colour reflects observed events, not a saturation threshold")
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

    /// A CATEGORY encoding - which of the five products a node belongs to -
    /// never a verdict. Deliberately disjoint from `color(_ level:)`'s
    /// green/orange/red vocabulary and from the orange "not deployed" mark:
    /// this graph shows product and observed level side by side on the same
    /// chip, so a shared hue between the two would be read as a severity the
    /// Cluster and Metrics tabs are not allowed to assign.
    // ponytail: hardcoded five-entry palette; a sixth first-class product
    // falls back to grey rather than crashing. Upgrade path is hashing the
    // product name into a stable hue, which is only worth it if the stack
    // ever grows past what five hand-picked, mutually distinguishable
    // colours can cover.
    static func productColor(_ product: String) -> Color {
        switch product {
        case "mimir":   return .purple
        case "loki":    return .blue
        case "tempo":   return .teal
        case "alloy":   return .pink
        case "grafana": return .brown
        default:        return .gray
        }
    }

    // MARK: - Canvas

    private func canvasSize(_ placed: [(node: LgtmGraphNode, tier: Int, slot: Int)]) -> CGSize {
        let tiers = CGFloat((placed.map(\.tier).max() ?? 0) + 1)
        let slots = CGFloat((placed.map(\.slot).max() ?? 0) + 1)
        return CGSize(width: slots * (Self.nodeW + Self.slotGap) - Self.slotGap,
                      height: tiers * (Self.nodeH + Self.tierGap) - Self.tierGap)
    }

    private func point(_ tier: Int, _ slot: Int) -> CGPoint {
        CGPoint(x: CGFloat(slot) * (Self.nodeW + Self.slotGap) + Self.nodeW / 2,
                y: CGFloat(tier) * (Self.nodeH + Self.tierGap) + Self.nodeH / 2)
    }

    /// The graph is a fixed-size `Canvas` + positioned chips inside a
    /// `ScrollView`, not the pan/zoom container `NamespaceGraphView` uses.
    /// That custom gesture handling earns its keep there because a busy
    /// namespace can be thousands of points tall; even merged, this graph
    /// tops out around 32 nodes and scrolls like any other content - a
    /// second gesture-driven pan/zoom implementation would be solving a
    /// problem this view doesn't have.
    private var canvasContent: some View {
        let laid = placed
        let size = canvasSize(laid)
        var points: [String: CGPoint] = [:]
        var productByID: [String: String] = [:]
        for p in laid {
            points[p.node.id] = point(p.tier, p.slot)
            productByID[p.node.id] = p.node.product
        }
        let w = max(size.width, Self.nodeW)
        let h = max(size.height, Self.nodeH)

        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for e in edges {
                    guard let a = points[e.from], let b = points[e.to] else { continue }
                    // Coloured by the SOURCE product, so Alloy's fan-out into
                    // three different products' distributors reads as one
                    // family of edges leaving one place.
                    drawEdge(&ctx, from: a, to: b, verb: e.verb,
                             color: Self.productColor(productByID[e.from] ?? ""))
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

    /// Curve + arrowhead + verb label, running downwards: leaves the bottom
    /// edge of the source chip, enters the top edge of the target. Mirrors
    /// the technique `NamespaceGraphView` uses for its own Canvas edges
    /// (resolved `Text` with `.shading` set explicitly, not
    /// `.foregroundStyle` on the `Text` itself, which Canvas's `resolve`
    /// doesn't carry through) - same problem, same proven fix, written fresh
    /// here since that file is out of this lane.
    private func drawEdge(_ ctx: inout GraphicsContext, from start0: CGPoint, to end0: CGPoint,
                          verb: String, color: Color) {
        let start = CGPoint(x: start0.x, y: start0.y + Self.nodeH / 2)
        let end = CGPoint(x: end0.x, y: end0.y - Self.nodeH / 2)
        let bend = max((end.y - start.y) * 0.45, 14)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end,
                      control1: CGPoint(x: start.x, y: start.y + bend),
                      control2: CGPoint(x: end.x, y: end.y - bend))
        ctx.stroke(path, with: .color(color.opacity(0.5)), lineWidth: 1.2)

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
            ctx.fill(arrow, with: .color(color.opacity(0.85)))
        }

        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        var text = ctx.resolve(Text(verb).font(.system(size: 8, weight: .medium)))
        text.shading = .color(.secondary)
        let measured = text.measure(in: CGSize(width: Self.nodeW, height: 20))
        ctx.fill(Path(roundedRect: CGRect(x: mid.x - measured.width / 2 - 2, y: mid.y - measured.height / 2,
                                          width: measured.width + 4, height: measured.height),
                      cornerRadius: 2),
                 with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.9)))
        ctx.draw(text, at: mid, anchor: .center)
    }
}

// MARK: - Layout

/// Pure tiering over an arbitrary node/edge list - no SwiftUI, so it can be
/// exercised directly the way `ResourceGraph`'s layout is. `tier` is
/// longest-path-from-source via Kahn's algorithm rather than
/// `ResourceGraph`'s static kind-based column table: `ResourceGraph.column`
/// works because `ResourceKind` gives it a fixed small vocabulary to switch
/// on, but a logical role node carries no `ResourceKind` (forcing one would
/// mean inventing a fake kind per LGTM role, worse than writing the ~20
/// lines below), and this file already has the real edges in hand, which
/// make longest-path tiering both correct and cheap at this node count.
///
/// The vocabulary is `tier`/`slot`, not `column`/`row`, because the renderer
/// draws the flow downwards: tier is the position ALONG the flow (y here),
/// slot the position across it (x).
enum LgtmGraphLayout {
    /// Breaks slot ties: keeps the hot path (write, then read) ahead of
    /// caches and maintenance. Secondary to the barycenter now that the graph
    /// is merged - see `place` - but it is the whole ordering for tier 0,
    /// where nothing has a parent to sit under yet.
    static let lanePriority: [LgtmLane: Int] = [.write: 0, .read: 1, .standalone: 2, .maintenance: 3, .cache: 4]

    static func place(nodes: [LgtmGraphNode], edges: [LgtmFlowEdge]) -> [(node: LgtmGraphNode, tier: Int, slot: Int)] {
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

        var tier: [String: Int] = [:]
        var queue = connected.filter { (indegree[$0.id] ?? 0) == 0 }.map(\.id)
        var head = 0
        for id in queue { tier[id] = 0 }
        while head < queue.count {
            let id = queue[head]; head += 1
            let t = tier[id] ?? 0
            for next in outgoing[id] ?? [] {
                indegree[next, default: 0] -= 1
                tier[next] = max(tier[next] ?? 0, t + 1)
                if indegree[next] == 0 { queue.append(next) }
            }
        }
        // Anything left has indegree > 0 forever - it's on a cycle. The real
        // topologies never are (see `LgtmTopology.selfCheck`, which asserts
        // it of the merged edge list too), but a bad edge table reaching this
        // code must render, not hang: park whatever's left after the furthest
        // tier Kahn's algorithm actually resolved, one pass, no recursion
        // back into the cycle.
        let resolvedMax = tier.values.max() ?? 0
        for n in connected where tier[n.id] == nil {
            tier[n.id] = resolvedMax + 1
        }
        // Nodes with no edges at all get their own placement rule: if
        // *nothing* has edges (a caller-supplied node set this topology has
        // no entry for), spread them by lane so the graph still shows
        // structure instead of one indistinguishable stack. If only *some*
        // nodes are edge-free (e.g. Mimir's overrides-exporter, which
        // genuinely has none), shelve them together after the real flow
        // instead of crowding tier 0 next to genuine sources.
        if !isolated.isEmpty {
            if connected.isEmpty {
                for n in isolated { tier[n.id] = lanePriority[n.lane] ?? 2 }
            } else {
                let shelf = (tier.values.max() ?? -1) + 1
                for n in isolated { tier[n.id] = shelf }
            }
        }

        // Slots: barycenter of already-placed parents FIRST, then lane, then
        // id for a total, deterministic order. Barycenter leads because the
        // graph is merged now - most edges are intra-product, so pulling each
        // node under its own parents is what keeps mimir, loki and tempo as
        // three legible columns instead of interleaving them by lane across
        // the whole width. Lane still decides tier 0 outright (nothing there
        // has a parent, so every barycenter ties) and breaks ties below it.
        var parents: [String: [String]] = [:]
        for e in liveEdges { parents[e.to, default: []].append(e.from) }
        var slot: [String: Int] = [:]
        let maxTier = tier.values.max() ?? 0
        for t in 0...maxTier {
            let inTier = nodes.filter { tier[$0.id] == t }
            let ordered = inTier.sorted { a, b in
                let ba = barycenter(a.id, parents, slot), bb = barycenter(b.id, parents, slot)
                if ba != bb { return ba < bb }
                let la = lanePriority[a.lane] ?? 9, lb = lanePriority[b.lane] ?? 9
                if la != lb { return la < lb }
                return a.id < b.id
            }
            for (s, n) in ordered.enumerated() { slot[n.id] = s }
        }

        return nodes.map { (node: $0, tier: tier[$0.id] ?? 0, slot: slot[$0.id] ?? 0) }
    }

    private static func barycenter(_ id: String, _ parents: [String: [String]], _ slot: [String: Int]) -> Double {
        let slots = (parents[id] ?? []).compactMap { slot[$0] }
        guard !slots.isEmpty else { return .greatestFiniteMagnitude }
        return Double(slots.reduce(0, +)) / Double(slots.count)
    }
}

// MARK: - Chip

private struct Chip: View {
    let node: LgtmGraphNode
    let onTap: (() -> Void)?

    /// Past this many pods the pips stop being countable at 5pt and start
    /// being a texture, so the rest collapse into a "+N". The exact set is
    /// never lost - `PodInspectSheet` (Cluster tab) and `PodBreakdown`
    /// (Metrics tab) both already show every pod individually, which is why
    /// this chip only has to say "how many, and are any unhappy".
    private static let visiblePods = 14

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
    private var productColor: Color { LgtmGraphView.productColor(node.product) }

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

    /// What the tooltip says for a present node - `node.detail`, the exact
    /// (unclamped) peak reading when there is one, and the pod count. Only
    /// the pods that are actually unhappy get named: with 31 Alloy pods in a
    /// metrics window, listing every name turns the tooltip into a wall, and
    /// the full per-pod detail already lives in `PodInspectSheet` and the
    /// per-pod bars on each tab's cards.
    private var presentHelpText: String {
        var parts = ["\(node.label) - \(node.detail)"]
        if let p = node.peakReplicaSaturation, p.isFinite {
            parts.append("busiest replica \(Int((max(p, 0) * 100).rounded()))%")
        }
        if !node.pods.isEmpty {
            var pods = "\(node.pods.count) pod\(node.pods.count == 1 ? "" : "s")"
            let unhappy = node.pods.filter { $0.level == .warn || $0.level == .critical }
            if !unhappy.isEmpty { pods += " (" + unhappy.map(\.name).joined(separator: ", ") + ")" }
            parts.append(pods)
        }
        return parts.joined(separator: " · ")
    }

    /// One mark per pod, coloured by that pod's own observed state - the
    /// difference between "this component is a box" and "this component is
    /// three copies, one of which is unhappy". Deliberately not a second
    /// number: it is the cheapest thing that makes a node's replicas visible
    /// without duplicating the per-pod detail that already has two homes.
    @ViewBuilder
    private var podPips: some View {
        if !node.pods.isEmpty {
            HStack(spacing: 3) {
                ForEach(node.pods.prefix(Self.visiblePods), id: \.name) { pod in
                    Circle()
                        .fill(LgtmGraphView.color(pod.level).opacity(0.85))
                        .frame(width: 5, height: 5)
                }
                if node.pods.count > Self.visiblePods {
                    Text("+\(node.pods.count - Self.visiblePods)")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
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
            // Product first, then lane: in a merged graph "which product"
            // is the thing a reader is orienting by, and carrying it in the
            // product hue as well as in words means the graph stays readable
            // to someone who can't tell purple from blue.
            Text(node.product.isEmpty ? node.lane.rawValue : "\(node.product) · \(node.lane.rawValue)")
                .font(.system(size: 8, weight: .medium))
                .textCase(.uppercase)
                .kerning(0.4)
                .foregroundStyle(productColor)
                .lineLimit(1)
            Text(node.present ? node.detail : "not deployed")
                .font(.caption2)
                .fontWeight(node.present ? .regular : .semibold)
                .foregroundStyle(node.present ? Color.secondary : Color.orange)
                .lineLimit(2)
            podPips
        }
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(width: LgtmGraphView.nodeW, height: LgtmGraphView.nodeH, alignment: .leading)
        .background(
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                    // The product tint. Low enough that the saturation fill
                    // drawn over it still reads as the louder of the two -
                    // category is context, load is the thing being reported.
                    RoundedRectangle(cornerRadius: 8).fill(productColor.opacity(0.10))
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
                    // The product stripe, drawn last so the saturation fill
                    // can't swallow it. Rounded on the leading side only, so
                    // it sits flush inside the chip's own corner radius.
                    UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                        .fill(productColor)
                        .frame(width: 4)
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
/// Covers the properties that matter for a GUI, not just correctness: the
/// tiering never hangs (the whole point of testing a cycle), every node -
/// including one with no edges at all - still gets placed somewhere rather
/// than silently dropped, and the merged whole-stack graph the two tabs
/// actually draw tiers into a shape that runs down the page instead of
/// collapsing into one enormous row.
extension LgtmGraphLayout {
    static func selfCheck() {
        func node(_ id: String, lane: LgtmLane = .standalone, product: String = "test") -> LgtmGraphNode {
            LgtmGraphNode(id: id, product: product, label: id, detail: "", lane: lane,
                          level: .unknown, saturation: nil, present: true)
        }

        assert(place(nodes: [], edges: []).isEmpty, "zero nodes must not crash")
        assert(place(nodes: [node("a")], edges: []).count == 1, "a single node must place cleanly")

        let chain = place(nodes: [node("a"), node("b"), node("c")],
                          edges: [LgtmFlowEdge(from: "a", to: "b", verb: "x"),
                                  LgtmFlowEdge(from: "b", to: "c", verb: "x")])
        func chainTier(_ id: String) -> Int { chain.first { $0.node.id == id }!.tier }
        assert(chainTier("a") < chainTier("b") && chainTier("b") < chainTier("c"),
               "a straight chain must strictly increase in tier")

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
        assert(Set(noEdges.map(\.tier)).count == 2, "with zero edges, lane fallback must still separate write from read")

        // A node with no edges at all, alongside a real chain, must not sit
        // in tier 0 next to genuine sources.
        let mixed = place(nodes: [node("a"), node("b"), node("iso")],
                          edges: [LgtmFlowEdge(from: "a", to: "b", verb: "x")])
        let isoTier = mixed.first { $0.node.id == "iso" }!.tier
        let bTier = mixed.first { $0.node.id == "b" }!.tier
        assert(isoTier > bTier, "an edge-free node must shelve after the real flow, not crowd its front")

        // The merged, whole-stack graph these two tabs actually draw: every
        // node of every product in one placement, built from the real edge
        // table rather than a toy one, since the properties that matter
        // (products keeping their relative tiering, cross-product seams
        // tiering ahead of what they feed) are properties of THAT data.
        let mergedEdges = LgtmTopology.allEdges
        let mergedIDs = Set(mergedEdges.flatMap { [$0.from, $0.to] }).sorted()
        let merged = place(nodes: mergedIDs.map { node($0, product: LgtmTopology.product(forNodeID: $0)) },
                           edges: mergedEdges)
        assert(merged.count == mergedIDs.count, "every merged node must be placed")
        var mergedTier: [String: Int] = [:]
        for p in merged { mergedTier[p.node.id] = p.tier }
        // Vertical means every edge runs strictly down the page. This is the
        // one property a reader relies on to follow the flow at all.
        for e in mergedEdges {
            assert((mergedTier[e.from] ?? 0) < (mergedTier[e.to] ?? 0),
                   "merged edge \(e.from) -> \(e.to) must run down the page")
        }
        // Each product keeps its own relative order inside the merged graph.
        assert(mergedTier["mimir/nginx"]! < mergedTier["mimir/distributor"]!)
        assert(mergedTier["mimir/distributor"]! < mergedTier["mimir/ingester"]!)
        assert(mergedTier["loki/gateway"]! < mergedTier["loki/ingester"]!)
        assert(mergedTier["tempo/distributor"]! < mergedTier["tempo/compactor"]!)
        // The cross-product seams - the whole reason for merging - tier ahead
        // of every product they feed or read.
        for target in ["mimir/distributor", "loki/distributor", "tempo/distributor"] {
            assert(mergedTier["alloy"]! < mergedTier[target]!, "alloy must tier ahead of \(target)")
        }
        for target in ["mimir/query-frontend", "loki/query-frontend", "tempo/query-frontend"] {
            assert(mergedTier["grafana"]! < mergedTier[target]!, "grafana must tier ahead of \(target)")
        }
        // Neither degenerate shape: not one enormous row, not one enormous
        // column. Three products' worth of chains genuinely interleave.
        assert(Set(merged.map(\.tier)).count >= 6, "the merged stack must be deep, not one enormous row")
        assert(Set(merged.map(\.slot)).count >= 4, "the merged stack must be wide, not one enormous column")
    }
}
#endif
