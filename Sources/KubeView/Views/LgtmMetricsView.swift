import SwiftUI

/// Historical usage from the stack's own Mimir, over `report.windowSecs`. Sits
/// between the Cluster tab (what is true right now) and Findings (what to
/// change): this is the trend that justifies a finding, shown so someone can
/// see it for themselves rather than be told a conclusion.
///
/// Ground truth about what was MEASURED, per pod - not a verdict about what
/// it means. Thresholds, severity and "too big/too small" all belong to the
/// Findings tab; this tab reports facts (usage, limits, coverage, OOM kills,
/// throttling, restarts - things that happened) and lets the reader judge.
/// `HeadroomBar` draws magnitude and a limit marker, never a graded colour;
/// `LgtmNodeLevel` on the flow graph is driven only by observed events (over
/// a configured limit, an OOM kill, throttling recorded), never a predictive
/// cutoff like "90% is close enough to worry about".
///
/// Self-contained on purpose — it takes nothing but the already-fetched
/// `report`, so it owns its own empty state and its own rendering of
/// `report.warning` rather than assuming a shared header does it.
struct LgtmMetricsView: View {
    let report: LgtmReport

    /// The component a graph node click most recently pointed at. Drives both
    /// the scroll-into-view and the highlighted card border, so "click a node"
    /// and "look at the matching card" always agree.
    @State private var selectedComponentID: String?
    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        Group {
            if !report.hasMetrics {
                noMetrics
            } else {
                metricsContent
            }
        }
        .onAppear {
            #if DEBUG
            LgtmMetricsView.selfCheck()
            #endif
        }
    }

    // MARK: - No metrics

    /// `metricsAvailable == false` means every `usage` field on every
    /// component is a zero the analyser never tried to fill in — rendering
    /// bars and sparklines against that would present absence as fact.
    private var noMetrics: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("No metrics queried", systemImage: "chart.line.downtrend.xyaxis")
            } description: {
                Text("This report was produced without querying the metrics store, so every usage number here would read as zero rather than real. Check the Cluster tab for live state, or re-run the analysis.")
                    .multilineTextAlignment(.center)
            }
            // Still shown here even though it talks about metrics store
            // aggregation — a caveat about the store's shape is true
            // independent of whether this particular run queried it.
            if let warning = report.warning, !warning.isEmpty {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Content

    private var metricsContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let warning = report.warning, !warning.isEmpty {
                        warningBanner(warning)
                    }
                    if let note = storeCoverageNote {
                        storeCoverageBanner(note)
                    }
                    statStrip
                    stackSummary
                    productSection
                }
                .padding()
            }
            // Read once rather than threading a proxy through every helper —
            // the graph's onSelect is the only thing that needs it, and it
            // needs it lazily (the user has to click a node first).
            .onAppear { scrollProxy = proxy }
        }
    }

    /// Deliberately louder than the caveat strip in the Cluster/Findings
    /// header: this whole tab is a set of numbers built to be compared
    /// against each other, and the one thing that can silently invalidate
    /// every comparison is "these are actually five clusters' worth of
    /// peaks, blended."
    private func warningBanner(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Every number below may be inflated")
                    .font(.callout.weight(.semibold))
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    /// The one honest headline when most components fall short of the
    /// window: not "these 27 components have short coverage" (fires on
    /// every card, becomes wallpaper, gets ignored), but "the store itself
    /// doesn't hold what the window asked for". Said once, near the top,
    /// distinct in colour from the multi-cluster warning above it so the
    /// two caveats stay visually separable. This also directly answers a
    /// question the window picker now raises on its own: picking 30d does
    /// not mean you get 30d back if Mimir's retention is 8d.
    private func storeCoverageBanner(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.title3)
                .foregroundStyle(.blue)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.35), lineWidth: 1)
        )
    }

    /// `nil` when the store's typical (median) coverage isn't materially
    /// short of the requested window - nothing to say. The 0.9 cutoff used
    /// to gate a per-card badge on every component; it now gates this one
    /// stack-wide statement instead, and per-card badges are driven by
    /// `isCoverageOutlier` (relative to the store's own median), not by
    /// this absolute distance from the window.
    private var storeCoverageNote: String? {
        guard !report.components.isEmpty, report.windowSecs > 0,
              medianCoverage < report.windowSecs * 0.9 else { return nil }
        return "This store holds about \(formatDuration(medianCoverage)) of history for most components, against the \(formatDuration(report.windowSecs)) window requested - every number below reflects that shorter span, not the window you picked."
    }

    // MARK: - Stat strip

    private var overLimitCount: Int {
        report.components.filter { headroomRatio($0).map { $0 > 1 } ?? false }.count
    }

    private var statStrip: some View {
        let comps = report.components
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            StatCard(label: "Components", value: "\(comps.count)",
                     icon: "square.stack.3d.up", color: .accentColor)
            StatCard(label: "Window", value: formatDuration(report.windowSecs),
                     icon: "clock", color: .secondary)
            StatCard(label: "Coverage Outliers", value: "\(coverageOutliers.count)",
                     icon: "clock.badge.exclamationmark",
                     color: coverageOutliers.isEmpty ? .secondary : .orange)
            StatCard(label: "Over Limit", value: "\(overLimitCount)",
                     icon: "exclamationmark.triangle",
                     color: overLimitCount > 0 ? .red : .secondary)
        }
    }

    // MARK: - Stack totals

    /// "How much of what we reserved are we really using" is the single most
    /// useful fact on this tab, so it leads. CPU limits are opt-in and this
    /// stack mostly skips them (see `MetricsRollup`), so a "vs limit" figure
    /// only means something over the subset that actually has one — shown
    /// via the same restricted-subset rollup used per-product below.
    private var stackSummary: some View {
        let rollup = MetricsRollup(report.components)
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Stack totals",
                          trailing: "\(rollup.count) components · p99 over the window")
            HStack(alignment: .top, spacing: 16) {
                resourceColumn(title: "Memory",
                                requestUsed: rollup.memP99AllComponents, request: rollup.memRequest,
                                limitUsed: rollup.memP99LimitedComponents, limit: rollup.memLimit,
                                limitedCount: rollup.memLimitedCount, totalCount: rollup.count,
                                format: ResourceParser.formatBytes)
                resourceColumn(title: "CPU",
                                requestUsed: rollup.cpuP99AllComponents, request: rollup.cpuRequest,
                                limitUsed: rollup.cpuP99LimitedComponents, limit: rollup.cpuLimit,
                                limitedCount: rollup.cpuLimitedCount, totalCount: rollup.count,
                                format: ResourceParser.formatMillicores)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func resourceColumn(title: String, requestUsed: Double, request: Double,
                                 limitUsed: Double, limit: Double,
                                 limitedCount: Int, totalCount: Int,
                                 format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HeadroomBar(label: "p99 vs request", used: requestUsed, total: request, format: format)
            HeadroomBar(label: "p99 vs limit", used: limitUsed, total: limit, format: format)
            if limitedCount < totalCount {
                Text(limitedCount == 0
                     ? "no component sets a \(title.lowercased()) limit"
                     : "limit set on \(limitedCount)/\(totalCount) components — the rest are excluded above")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - By product (grouped list + flow graph)

    /// Median coverage across the report - "what a typical component here
    /// actually has", used both by `storeCoverageNote` and as the baseline
    /// every per-card outlier badge measures against.
    private var medianCoverage: Double { medianCoverageSecs(report.components) }

    /// Components whose coverage is materially below their own report's
    /// median - see `isCoverageOutlier` for why median-relative rather than
    /// window-relative.
    private var coverageOutliers: [LgtmComponent] {
        let median = medianCoverage
        return report.components.filter { isCoverageOutlier($0, median: median) }
    }

    /// Grouped by product (mimir/loki/tempo/...), each group headroom-ordered
    /// internally - see `groupByProduct`.
    private var productGroups: [ProductGroup] { groupByProduct(report.components) }

    private var productSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "By product",
                          trailing: "\(productGroups.count) products · \(report.components.count) components")
            ForEach(productGroups) { group in
                productGroupSection(group)
            }
        }
    }

    /// One product's rollup card as the group header, its data-flow graph,
    /// then its own components - headroom-ordered, never mixed with another
    /// product's. Grouping by `product` rather than `role` is deliberate: the
    /// four Mimir caches all share `role == "memcached"` (it's a Helm label,
    /// not the workload name) but have distinct `title`s, so a role-keyed
    /// grouping would silently collapse them back into one.
    private func productGroupSection(_ group: ProductGroup) -> some View {
        let edges = LgtmTopology.edges(for: group.product)
        let nodes = nodesForGraph(product: group.product, components: group.components, edges: edges)
        let outliers = group.components.filter { isCoverageOutlier($0, median: medianCoverage) }.count

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProductRollupCard(product: group.product, rollup: group.rollup)
                    .frame(maxWidth: 420, alignment: .leading)
                Spacer(minLength: 0)
            }
            LgtmGraphView(product: group.product, nodes: nodes, edges: edges) { id in
                selectedComponentID = id
                withAnimation { scrollProxy?.scrollTo(id, anchor: .center) }
            }
            .frame(minHeight: 140)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10)], spacing: 10) {
                ForEach(group.components) { component in
                    MetricsComponentCard(component: component,
                                          windowSecs: report.windowSecs,
                                          isCoverageOutlier: isCoverageOutlier(component, median: medianCoverage),
                                          isSelected: component.title == selectedComponentID)
                        .id(component.title)
                }
            }
            if outliers > 0 {
                Text("\(outliers) of \(group.components.count) in this group have outlier coverage")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Aggregation

/// Sums usage/reservation across a set of components. CPU limits are opt-in
/// in Kubernetes and this stack mostly skips them (27 of 30 real components
/// have `cpuLimitMillis == 0`), so summing every component's p99 against only
/// the limited ones' capacity would compare unrelated things — a component
/// with no cap contributes usage but no capacity, which inflates the ratio
/// against a denominator that never claimed to cover it. Both `...Limited...`
/// fields restrict to the same subset on numerator and denominator, for both
/// memory and CPU, so the "vs limit" comparison never mixes capped and
/// uncapped components.
private struct MetricsRollup {
    let count: Int

    let memRequest: Double
    let memP99AllComponents: Double
    let memLimit: Double
    let memP99LimitedComponents: Double
    let memLimitedCount: Int

    let cpuRequest: Double
    let cpuP99AllComponents: Double
    let cpuLimit: Double
    let cpuP99LimitedComponents: Double
    let cpuLimitedCount: Int

    init(_ components: [LgtmComponent]) {
        count = components.count

        memRequest = components.reduce(0) { $0 + Double($1.memRequestBytes) }
        memP99AllComponents = components.reduce(0) { $0 + $1.usage.memP99Bytes }
        let memLimited = components.filter { $0.memLimitBytes > 0 }
        memLimit = memLimited.reduce(0) { $0 + Double($1.memLimitBytes) }
        memP99LimitedComponents = memLimited.reduce(0) { $0 + $1.usage.memP99Bytes }
        memLimitedCount = memLimited.count

        cpuRequest = components.reduce(0) { $0 + Double($1.cpuRequestMillis) }
        cpuP99AllComponents = components.reduce(0) { $0 + $1.usage.cpuP99Millis }
        let cpuLimited = components.filter { $0.cpuLimitMillis > 0 }
        cpuLimit = cpuLimited.reduce(0) { $0 + Double($1.cpuLimitMillis) }
        cpuP99LimitedComponents = cpuLimited.reduce(0) { $0 + $1.usage.cpuP99Millis }
        cpuLimitedCount = cpuLimited.count
    }
}

/// One product's components, already headroom-ordered - see `groupByProduct`.
private struct ProductGroup: Identifiable {
    let product: String
    let rollup: MetricsRollup
    let components: [LgtmComponent]
    var id: String { product }
}

/// Groups by `product`, never by `role` - see `productGroupSection` for why
/// (the four Mimir caches share one role but must stay four groups' worth of
/// nothing, i.e. distinct entries within ONE mimir group). Groups are ordered
/// by aggregate mem p99 descending, same as the old flat product-rollup list -
/// "which part of the stack dominates" is still a usage question. Each
/// group's own components stay headroom-ordered internally (`headroomOrdered`)
/// since that ordering is still the actionable one once you're looking at a
/// single product.
private func groupByProduct(_ components: [LgtmComponent]) -> [ProductGroup] {
    Dictionary(grouping: components, by: \.product)
        .map { ProductGroup(product: $0.key, rollup: MetricsRollup($0.value), components: headroomOrdered($0.value)) }
        .sorted { $0.rollup.memP99AllComponents > $1.rollup.memP99AllComponents }
}

/// `nil` when the component has no memory limit — "can't be judged", not
/// "0% used". Kept as a free function (rather than a method) so both the view
/// and `selfCheck()` call the identical logic instead of a copy that could
/// drift from it. Always max-across-pods (that's what `usage.memP99Bytes`
/// already is, per the Go analyser), used for ordering/rollups where a single
/// worst-case number is what's actionable - the average/peak split lives
/// separately in `memoryRatios`, for the graph nodes specifically.
private func headroomRatio(_ c: LgtmComponent) -> Double? {
    guard c.memLimitBytes > 0 else { return nil }
    return c.usage.memP99Bytes / Double(c.memLimitBytes)
}

private func headroomOrdered(_ components: [LgtmComponent]) -> [LgtmComponent] {
    components.sorted { a, b in
        switch (headroomRatio(a), headroomRatio(b)) {
        case let (ra?, rb?): return ra > rb
        case (nil, nil):     return a.usage.memP99Bytes > b.usage.memP99Bytes
        case (nil, _):       return false   // a has no limit -> sorts after b
        case (_, nil):       return true    // b has no limit -> a sorts before
        }
    }
}

/// Shared by `medianCoverageSecs` and `memoryRatios` - both want "what's
/// typical here", not "what's the mean", for the same reason: a small
/// sample with a couple of flyers on one side (a retention floor everyone
/// hits, one component that just deployed; or a busiest replica pulling a
/// mean toward it) drags a mean away from what "normal" actually looks like.
private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let mid = sorted.count / 2
    if sorted.count.isMultiple(of: 2) { return (sorted[mid - 1] + sorted[mid]) / 2 }
    return sorted[mid]
}

private func medianCoverageSecs(_ components: [LgtmComponent]) -> Double {
    median(components.map { $0.usage.coverageSecs })
}

/// A component's coverage is judged against its own report's median, not
/// against the requested window - the window-vs-store gap is a single fact
/// about the store (`storeCoverageNote`), true for nearly everyone at once
/// and not worth repeating 30 times. A per-card badge should fire only when
/// a component is short even relative to its neighbours: "alloy has 1 day
/// where everything else has 8" is a signal about that one component's
/// trustworthiness; "everything has 8 instead of the requested 14" is not
/// something 30 repeated badges should carry. Half the median is a coarse
/// but effective cut for "materially below the pack".
///
/// At the 24h default window this rarely fires at all: retention (~8d) far
/// exceeds the window, so nearly every component's coverage sits at or near
/// the full window rather than being capped short of it the way 14d used to
/// cap everyone at ~8d. What still trips it is a component that has existed
/// for less than half the window - i.e. deployed within the last ~12h - which
/// is exactly the case worth flagging ("this number is from a pod that just
/// started, take it with a grain of salt"), so the median-relative rule stays
/// meaningful even though the population it flags looks different day to day.
private func isCoverageOutlier(_ component: LgtmComponent, median: Double) -> Bool {
    median > 0 && component.usage.coverageSecs < median * 0.5
}

// MARK: - Graph nodes

/// Nodes for one product's data-flow graph: every component actually present
/// in the report, plus - id for id - anything the topology expects but the
/// report doesn't contain (`present: false`, so a gap in the data path is
/// visible instead of silently missing a node). A product `LgtmTopology`
/// doesn't know the shape of contributes `edges == []`, which still yields
/// the present-only nodes - the graph still renders something, just with
/// nothing to connect them.
private func nodesForGraph(product: String, components: [LgtmComponent], edges: [LgtmFlowEdge]) -> [LgtmGraphNode] {
    let expectedIDs = Set(edges.flatMap { [$0.from, $0.to] })
    let byID = Dictionary(components.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
    let orderedIDs = expectedIDs.union(byID.keys).sorted { a, b in
        let laneA = laneRank(laneFor(id: a, component: byID[a], product: product))
        let laneB = laneRank(laneFor(id: b, component: byID[b], product: product))
        return laneA != laneB ? laneA < laneB : a < b
    }
    return orderedIDs.map { id in
        let component = byID[id]
        let ratios = component.map(memoryRatios) ?? (typical: nil, peak: nil)
        return LgtmGraphNode(
            id: id,
            label: nodeLabel(id: id, product: product),
            detail: component.map { nodeDetail($0, typical: ratios.typical, peak: ratios.peak) } ?? "not present",
            lane: laneFor(id: id, component: component, product: product),
            level: component.map {
                nodeLevel(ratio: ratios.peak ?? ratios.typical,
                          oomContainers: $0.usage.oomContainers, throttleRatio: $0.usage.throttleRatio)
            } ?? .unknown,
            // Raw, unclamped - the renderer clamps for its own drawn fill
            // (`Chip.fillFraction` in LgtmGraphView.swift) and nowhere
            // earlier. A producer that clamps before handing a ratio over is
            // exactly the bug class documented in this repo's CLAUDE.md: it
            // silently turns a real 198%-of-limit reading into a "100%" that
            // looks fine.
            saturation: ratios.typical,
            peakReplicaSaturation: ratios.peak,
            present: component != nil
        )
    }
}

/// `LgtmComponent.role` for a real node; for one the topology expects but the
/// report doesn't contain, the id's own suffix after "product/" (via
/// `nodeLabel`). Exact for every node this stack actually models except a
/// MISSING Mimir cache, whose real role ("memcached") differs from its title
/// suffix ("chunks-cache" etc.) - but that only affects a node with no data
/// behind it anyway, where a slightly-off lane is a cosmetic nit.
// ponytail: id-suffix role fallback for absent nodes; upgrade path is
// `LgtmTopology` exposing expected (id, role) pairs instead of bare ids, if a
// missing-cache lane assignment ever turns out to matter in practice.
private func laneFor(id: String, component: LgtmComponent?, product: String) -> LgtmLane {
    let role = component?.role ?? nodeLabel(id: id, product: product)
    return LgtmTopology.lane(product: product, role: role)
}

private func laneRank(_ lane: LgtmLane) -> Int {
    LgtmLane.allCases.firstIndex(of: lane) ?? LgtmLane.allCases.count
}

private func nodeLabel(id: String, product: String) -> String {
    id.hasPrefix(product + "/") ? String(id.dropFirst(product.count + 1)) : id
}

/// The graph node's own saturation is the MEDIAN across measured replicas,
/// not the worst one - "typical copy's load", which is what a fill bar
/// reads as at a glance across many nodes. Median over mean for the same
/// reason `medianCoverageSecs` picks it: with 2-3 replicas a mean is just
/// the midpoint and adds nothing a peak doesn't already say, and a real
/// busiest-replica outlier drags a mean toward itself in exactly the case
/// this field exists to describe honestly. `peak` is the busiest replica's
/// own ratio, carried separately so the graph can still mark "one copy is
/// doing all the work" even while the typical reading looks fine (see
/// `nodeLevel`, which judges `peak`, never `typical`, for that reason).
///
/// Two cases return `peak == nil` rather than a value: fewer than two
/// measured replicas (an older analyser, or a component this window only
/// ever saw one replica of - `typical` falls back to the same component-
/// level scalar used everywhere else on this tab, already max-across-pods
/// by construction), and a peak that lands within noise of `typical` (real
/// replicas measuring the same, or so close the two readings would draw as
/// the same point) - a tick sitting exactly on the fill it's meant to mark
/// against would read as a rendering bug, not as "perfectly balanced".
private func memoryRatios(_ component: LgtmComponent) -> (typical: Double?, peak: Double?) {
    guard component.memLimitBytes > 0 else { return (nil, nil) }
    let limit = Double(component.memLimitBytes)
    let pods = component.usage.replicas.filter { $0.memP99Bytes > 0 }
    guard pods.count > 1 else { return (headroomRatio(component), nil) }
    let values = pods.map(\.memP99Bytes)
    let typical = median(values) / limit
    let peak = (values.max() ?? median(values)) / limit
    guard abs(peak - typical) > 0.01 else { return (typical, nil) }
    return (typical, peak)
}

/// "1.7Gi p99" when there's no limit to compare against. "62% of limit" when
/// there is but `memoryRatios` found no peak worth reporting separately (one
/// measured replica, an older analyser, or the busiest replica is within
/// noise of typical). "62% typical · 90% peak of limit" once it genuinely
/// differs - the whole point of this rework: a flat "76%" hides exactly the
/// case someone opening this tab wants to see, one copy idle and one
/// carrying the load. Trusts `memoryRatios`'s own "is this worth mentioning"
/// call rather than a second threshold here, so the text and the graph's
/// peak tick can never disagree about whether there's a peak to show. Both
/// numbers unclamped on purpose - an over-limit reading should say so.
/// `saturation`/`peakReplicaSaturation` on the node are equally unclamped
/// (see `nodesForGraph`); only the renderer's own drawn fill clamps, never
/// this text and never the value handed to it.
private func nodeDetail(_ component: LgtmComponent, typical: Double?, peak: Double?) -> String {
    guard let typical else { return "\(ResourceParser.formatBytes(component.usage.memP99Bytes)) p99" }
    let typicalPct = Int((typical * 100).rounded())
    guard let peak else { return "\(typicalPct)% of limit" }
    return "\(typicalPct)% typical · \(Int((peak * 100).rounded()))% peak of limit"
}

/// Ground truth, not a verdict: every branch here is something that actually
/// happened, never a predicted "getting close". Critical is reserved for a
/// measured fact past a hard configured boundary - some replica's own p99
/// (`peak`, not the typical replica) at or over its memory limit, or an OOM
/// kill this window - either one wins outright regardless of the other's
/// reading, since both are independent hard facts. Warn is throttling actually recorded
/// (>0, not some picked minimum - a natural zero boundary, not a graded cut).
/// No limit and nothing else observed reads `.ok`, not "unknown" - unknown is
/// reserved for a node with no data at all (`present == false`).
private func nodeLevel(ratio: Double?, oomContainers: Double, throttleRatio: Double) -> LgtmNodeLevel {
    if let ratio, ratio >= 1.0 { return .critical }
    if oomContainers > 0 { return .critical }
    if throttleRatio > 0 { return .warn }
    return .ok
}

// ponytail: hardcoded five-entry product palette; a product name outside
// {mimir, loki, tempo, grafana, alloy} falls back to plain secondary gray
// rather than crashing. Upgrade path: hash the product string into a stable
// hue if the stack ever grows a sixth first-class product.
private func productColor(_ product: String) -> Color {
    switch product {
    case "mimir":   return .purple
    case "loki":    return .green
    case "tempo":   return .orange
    case "grafana": return .pink
    case "alloy":   return .blue
    default:        return .secondary
    }
}

private func formatDuration(_ seconds: Double) -> String {
    let days = seconds / 86400
    if days >= 1 { return String(format: "%.1fd", days) }
    return "\(Int(seconds / 3600))h"
}

// MARK: - Per-pod breakdown

/// The component's own name stripped off a pod's, leaving just what
/// distinguishes one replica from another: an ordinal ("0", "1", "2" for a
/// StatefulSet) or a ReplicaSet-hash-plus-random suffix (for a Deployment) -
/// which is also how a rollout's several generations show up as several
/// different suffixes for what is conceptually "the same" replica slot, see
/// `podCountNote`.
private func podSuffix(_ podName: String, component: LgtmComponent) -> String {
    let prefix = component.name + "-"
    return podName.hasPrefix(prefix) ? String(podName.dropFirst(prefix.count)) : podName
}

/// `nil` when the window's measured pod count matches today's replica count
/// - nothing to say. When they differ this states the fact plainly rather
/// than guessing WHY: a rollout mid-window, node churn on a DaemonSet, or a
/// scale event all produce the same symptom (more pods measured than are
/// live today) and this file has no reliable way to tell them apart from a
/// pod name alone - real spread observed live: mimir/querier's 2 replicas
/// showed up as 6 pods in one 24h window (three rollout generations).
private func podCountNote(_ component: LgtmComponent) -> String? {
    let measured = component.usage.replicas.count
    guard measured > 0, measured != component.replicas else { return nil }
    return "\(measured) pod\(measured == 1 ? "" : "s") measured this window vs \(component.replicas) replica\(component.replicas == 1 ? "" : "s") today - rollout or scaling churn, not necessarily \(measured) live copies"
}

/// The plain busiest/quietest fact, stated as a ratio - "one copy is taking
/// all the load" in one line, without judging whether that's a problem.
/// `nil` when there's nothing to compare (one replica) or the two are close
/// enough that reporting a ratio would just be noise (real replicas are
/// never bit-identical; 1% is comfortably past floating-point wobble).
private func spreadNote(_ usage: LgtmUsage) -> String? {
    guard let spread = usage.memorySpread, spread.low.memP99Bytes > 0 else { return nil }
    let ratio = spread.high.memP99Bytes / spread.low.memP99Bytes
    guard ratio > 1.01 else { return nil }
    return "\(ResourceParser.formatBytes(spread.low.memP99Bytes)) - \(ResourceParser.formatBytes(spread.high.memP99Bytes)) across replicas (\(String(format: "%.2fx", ratio)))"
}

/// Every measured replica, memory-heaviest first, top few shown and the rest
/// behind an explicit count - never silently dropped. `EmptyView` when there
/// is no per-pod data at all (an older analyser, where `usage.pods` is nil):
/// the rest of the card already falls back to the component-level scalars in
/// that case, so this section simply has nothing to add.
///
/// ponytail: memory only, no per-pod OOM/restart/throttle icons yet - those
/// stay component-level badges below. Upgrade path: a richer per-pod row if
/// a single memory bar per replica turns out not to be enough to spot which
/// one is in trouble.
private struct PodBreakdown: View {
    let component: LgtmComponent
    private static let visibleCount = 5

    private var sorted: [LgtmPodUsage] {
        component.usage.replicas.sorted { $0.memP99Bytes > $1.memP99Bytes }
    }

    var body: some View {
        if !sorted.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let note = podCountNote(component) { note2(note) }
                if let note = spreadNote(component.usage) { note2(note) }
                ForEach(Array(sorted.prefix(Self.visibleCount))) { pod in
                    HeadroomBar(label: podSuffix(pod.name, component: component),
                                used: pod.memP99Bytes, total: Double(component.memLimitBytes),
                                format: ResourceParser.formatBytes)
                }
                let hidden = Array(sorted.dropFirst(Self.visibleCount))
                if !hidden.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(hidden) { pod in
                                HeadroomBar(label: podSuffix(pod.name, component: component),
                                            used: pod.memP99Bytes, total: Double(component.memLimitBytes),
                                            format: ResourceParser.formatBytes)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("+\(hidden.count) more pod\(hidden.count == 1 ? "" : "s") measured this window")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                }
            }
        }
    }

    private func note2(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundStyle(.secondary)
    }
}

// MARK: - Cards

private struct ProductRollupCard: View {
    let product: String
    let rollup: MetricsRollup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(productColor(product)).frame(width: 8, height: 8)
                Text(product.capitalized).font(.callout.weight(.medium))
                Spacer()
                Text("\(rollup.count) component\(rollup.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HeadroomBar(label: "Mem p99 vs limit",
                        used: rollup.memP99LimitedComponents, total: rollup.memLimit,
                        format: ResourceParser.formatBytes)
            HeadroomBar(label: "CPU p99 vs request",
                        used: rollup.cpuP99AllComponents, total: rollup.cpuRequest,
                        format: ResourceParser.formatMillicores)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct MetricsComponentCard: View {
    let component: LgtmComponent
    let windowSecs: Double
    /// Computed once for the whole report by `LgtmMetricsView.isCoverageOutlier`
    /// (median-relative, not window-relative) rather than here per card - see
    /// that function for why.
    let isCoverageOutlier: Bool
    /// True when this card is what a graph node click most recently pointed
    /// at - drawn as a highlighted border so "click a node" has a visible
    /// destination in the grouped list below.
    let isSelected: Bool

    private var usage: LgtmUsage { component.usage }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isCoverageOutlier { coverageBadge }
            if !usage.series.isEmpty {
                Sparkline(values: usage.series).frame(height: 24)
            }
            HeadroomBar(label: "Mem p99", used: usage.memP99Bytes,
                        total: Double(component.memLimitBytes), format: ResourceParser.formatBytes)
            HeadroomBar(label: "Mem max", used: usage.memMaxBytes,
                        total: Double(component.memLimitBytes), format: ResourceParser.formatBytes)
            HeadroomBar(label: "CPU p99", used: usage.cpuP99Millis,
                        total: Double(component.cpuRequestMillis), format: ResourceParser.formatMillicores)
            PodBreakdown(component: component)
            badges
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(component.title).font(.callout.weight(.medium)).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(component.namespace)/\(component.name)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var coverageText: String {
        "\(formatDuration(usage.coverageSecs)) of \(formatDuration(windowSecs)) window"
    }

    private var coverageBadge: some View {
        Label(coverageText, systemImage: "clock.badge.exclamationmark")
            .font(.caption2)
            .foregroundStyle(.orange)
            .help("Far less history than its neighbours in this report - the least trustworthy numbers on this tab, not just short in absolute terms (see the coverage note above)")
    }

    /// Every badge here is a fact that happened this window, shown with one
    /// consistent accent once it happened at all - no internal grading by
    /// magnitude (a 6% throttle ratio used to read grey, "not really worth
    /// noting", which is exactly the kind of judgment call this tab no
    /// longer makes). The number itself still carries the real magnitude.
    private var badges: some View {
        HStack(spacing: 10) {
            // restarts/oomContainers come from a rate-style PromQL query over
            // the window, not a raw counter read, so they can be fractional —
            // truncating to Int reads as "count", which is close enough to be
            // useful and matches how LgtmComponentCard already shows it.
            if usage.restarts > 0 {
                Label("\(Int(usage.restarts)) restarts", systemImage: "arrow.clockwise")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if usage.oomContainers > 0 {
                Label("\(Int(usage.oomContainers)) OOM", systemImage: "memorychip")
                    .font(.caption2).foregroundStyle(.red)
            }
            if usage.throttleRatio > 0 {
                Label(String(format: "%.0f%% throttled", usage.throttleRatio * 100),
                      systemImage: "speedometer")
                    .font(.caption2).foregroundStyle(.orange)
            }
            Spacer()
        }
    }
}

// MARK: - Headroom bar

/// Draws headroom as a plain measurement, not a verdict. The fill is
/// literally `used` against a scale a little past whichever of `used`/`total`
/// is larger, and the thin marker is literally `total` - no colour tier for
/// "danger" or "waste" the way this used to work (red at >=90%, blue at
/// <=30%), because that tiering was a threshold this file picked, and under
/// this tab's "measure, don't grade" rule that judgment belongs to the
/// Findings tab, not here. A continuous colour ramp would have the same
/// problem in a subtler coat - it still says "red means bad", it just hides
/// where the line is drawn. The one thing that still gets an accent is a
/// measured fact that already happened: `used` past `total`, i.e. actually
/// over the configured limit - not a prediction that it might get there.
private struct HeadroomBar: View {
    let label: String
    let used: Double
    let total: Double
    let format: (Double) -> String

    private var ratio: Double? { total > 0 ? used / total : nil }
    private var overLimit: Bool { (ratio ?? 0) > 1 }

    /// A little past whichever of `used`/`total` is bigger, so the marker
    /// never sits flush on the bar's own right edge (unreadable as a marker
    /// there) and an over-limit fill has room to visibly pass it instead of
    /// clipping at the frame boundary. `max(..., 1)` keeps this off zero when
    /// both inputs are zero, which the fill-drawing guard below never asks it
    /// to divide by anyway, but costs nothing to make impossible outright.
    private var displayCeiling: Double { max(total, used, 1) * 1.2 }
    private var fillFraction: Double { max(used, 0) / displayCeiling }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let ratio {
                    Text(format(used)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Text("\(Int((ratio * 100).rounded()))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(overLimit ? Color.red : Color.primary)
                } else {
                    Text("\(format(used)) · not set").font(.caption2).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                    // No limit means no scale to draw against - "not set" in
                    // the label above already says so; inventing a bar here
                    // would imply a reference that doesn't exist.
                    if let ratio, ratio > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(overLimit ? Color.red : Color.accentColor)
                            .frame(width: geo.size.width * fillFraction)
                    }
                    if ratio != nil {
                        Rectangle()
                            .fill(Color.primary.opacity(0.5))
                            .frame(width: 1.5)
                            .offset(x: geo.size.width * (total / displayCeiling) - 0.75)
                    }
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Self check

#if DEBUG
extension LgtmMetricsView {
    /// Covers the non-trivial pure logic this file owns: `MetricsRollup`'s
    /// capped/uncapped subset restriction, `headroomOrdered` ranking,
    /// coverage-outlier detection, product grouping (the four Mimir memcached
    /// roles must not collapse into one), the graph-node derivation
    /// (level/saturation/presence, now event-only rather than a predictive
    /// cutoff), the average/peak per-pod split, and the churn/spread notes.
    static func selfCheck() {
        func pod(_ name: String, mem: Double, throttle: Double = 0, oom: Double = 0, restarts: Double = 0) -> LgtmPodUsage {
            LgtmPodUsage(name: name, memP99Bytes: mem, memMaxBytes: mem, cpuP99Millis: mem,
                         throttleRatio: throttle, oomContainers: oom, restarts: restarts)
        }
        func usage(_ p99: Double, cov: Double = 1, oom: Double = 0, throttle: Double = 0,
                   pods: [LgtmPodUsage]? = nil) -> LgtmUsage {
            LgtmUsage(memP99Bytes: p99, memMaxBytes: p99, cpuP99Millis: p99,
                      throttleRatio: throttle, oomContainers: oom, restarts: 0,
                      coverageSecs: cov, series: [], pods: pods)
        }
        func component(_ name: String, product: String = "mimir", role: String = "", title: String? = nil,
                        memLimit: Int, cpuLimit: Int = 0, p99: Double, replicas: Int = 1,
                        coverage: Double = 1, oom: Double = 0, throttle: Double = 0,
                        pods: [LgtmPodUsage]? = nil) -> LgtmComponent {
            LgtmComponent(name: name, namespace: "ns", kind: "Deployment", product: product,
                          role: role, zone: "", title: title ?? name, podPattern: nil,
                          replicas: replicas, readyReplicas: replicas, stateful: false,
                          cpuRequestMillis: 100, cpuLimitMillis: cpuLimit,
                          memRequestBytes: 100, memLimitBytes: memLimit,
                          usage: usage(p99, cov: coverage, oom: oom, throttle: throttle, pods: pods),
                          note: "", severity: "", findings: [])
        }

        // "a" has no CPU limit and must be excluded from BOTH sides of the
        // CPU-vs-limit figure, not just the denominator.
        let rollup = MetricsRollup([component("a", memLimit: 1000, cpuLimit: 0, p99: 10),
                                     component("b", memLimit: 1000, cpuLimit: 500, p99: 20)])
        assert(rollup.cpuLimitedCount == 1)
        assert(rollup.cpuLimit == 500)
        assert(rollup.cpuP99LimitedComponents == 20)     // not 30 — "a" excluded on both sides
        assert(rollup.cpuP99AllComponents == 30)          // the unrestricted total still sees both

        let ordered = headroomOrdered([
            component("low", memLimit: 1000, cpuLimit: 0, p99: 100),      // 10%
            component("high", memLimit: 1000, cpuLimit: 0, p99: 950),     // 95%
            component("nolimit", memLimit: 0, cpuLimit: 0, p99: 999_999)  // unranked, sorts last
        ])
        assert(ordered.map(\.name) == ["high", "low", "nolimit"])
        assert(headroomRatio(ordered[2]) == nil)

        // The shape actually observed against the live 30-component report
        // at a 14d window: a couple starved (1d), the bulk normal (8d), a
        // couple ahead (11d). The store-wide banner should fire (median 8d
        // is well short of 14d); per-card badges should fire ONLY for the
        // starved pair - not the bulk (the original bug: every card lit up),
        // and not the ahead pair (more history than typical isn't a trust
        // problem).
        let day: Double = 86400
        let window: Double = 14 * day
        var mix: [LgtmComponent] = []
        mix += (1...2).map { component("starved\($0)", memLimit: 1000, cpuLimit: 0, p99: 10, coverage: 1 * day) }
        mix += (1...6).map { component("normal\($0)", memLimit: 1000, cpuLimit: 0, p99: 10, coverage: 8 * day) }
        mix += (1...2).map { component("ahead\($0)", memLimit: 1000, cpuLimit: 0, p99: 10, coverage: 11 * day) }

        let median = medianCoverageSecs(mix)
        assert(median == 8 * day)
        assert(median < window * 0.9)   // store-wide banner would fire

        let outliers = Set(mix.filter { isCoverageOutlier($0, median: median) }.map(\.name))
        assert(outliers == Set(["starved1", "starved2"]))
        assert(outliers.isDisjoint(with: (1...6).map { "normal\($0)" }))
        assert(outliers.isDisjoint(with: ["ahead1", "ahead2"]))

        // Grouping: mixed products stay separate groups; within mimir the
        // four memcached-role caches (a Helm-label role, not the workload
        // name - see LgtmTopology.swift) stay four distinct entries, not one.
        let mixedProducts = [
            component("mimir-distributor", product: "mimir", role: "distributor",
                       title: "mimir/distributor", memLimit: 1000, p99: 950),   // 95%
            component("mimir-ingester", product: "mimir", role: "ingester",
                       title: "mimir/ingester", memLimit: 1000, p99: 100),      // 10%
            component("mimir-chunks-cache", product: "mimir", role: "memcached",
                       title: "mimir/chunks-cache", memLimit: 1000, p99: 500),
            component("mimir-index-cache", product: "mimir", role: "memcached",
                       title: "mimir/index-cache", memLimit: 1000, p99: 500),
            component("mimir-metadata-cache", product: "mimir", role: "memcached",
                       title: "mimir/metadata-cache", memLimit: 1000, p99: 500),
            component("mimir-results-cache", product: "mimir", role: "memcached",
                       title: "mimir/results-cache", memLimit: 1000, p99: 500),
            component("loki-querier", product: "loki", role: "querier",
                       title: "loki/querier", memLimit: 1000, p99: 800),
        ]
        let groups = groupByProduct(mixedProducts)
        assert(groups.map(\.product) == ["mimir", "loki"])   // mimir's aggregate p99 dominates -> sorts first
        assert(groups[0].components.count == 6)               // all four caches counted, not collapsed
        assert(Set(groups[0].components.map(\.title)) == Set([
            "mimir/distributor", "mimir/ingester", "mimir/chunks-cache",
            "mimir/index-cache", "mimir/metadata-cache", "mimir/results-cache"
        ]))
        assert(groups[0].components.first?.title == "mimir/distributor")  // headroom-ordered within the group

        // Node level: observed events only, no predictive cutoff. 0.99 used
        // to read `.warn` under the old 90% rule and must NOT any more - that
        // is the exact regression this rework removes.
        assert(nodeLevel(ratio: 1.0, oomContainers: 0, throttleRatio: 0) == .critical)
        assert(nodeLevel(ratio: 0.99, oomContainers: 0, throttleRatio: 0) == .ok)
        assert(nodeLevel(ratio: 0.5, oomContainers: 1, throttleRatio: 0) == .critical)   // OOM wins regardless of headroom
        assert(nodeLevel(ratio: 0.5, oomContainers: 0, throttleRatio: 0.001) == .warn)   // any recorded throttle, no minimum
        assert(nodeLevel(ratio: 0.5, oomContainers: 0, throttleRatio: 0) == .ok)
        assert(nodeLevel(ratio: nil, oomContainers: 0, throttleRatio: 0) == .ok)         // no limit, nothing else observed

        // memoryRatios: with <=1 measured replica, typical falls back to the
        // component-level (already max-across-pods) scalar and peak stays
        // nil - a second reading that would just repeat typical.
        let single = component("solo", memLimit: 1000, p99: 400)
        let soloRatios = memoryRatios(single)
        assert(soloRatios.typical == 0.4)
        assert(soloRatios.peak == nil)

        // Real spread (2 replicas, where median IS the midpoint - same
        // number a mean would give): typical and peak genuinely differ, and
        // the graph node's `saturation`/`peakReplicaSaturation`/`detail` all
        // reflect it. Critical judgement uses `peak`, not `typical` - proven
        // by a case where peak is over the limit but typical is comfortably
        // under it, which a typical-only reading would have missed entirely.
        let uneven = component("uneven", memLimit: 1000, p99: 900,
                                pods: [pod("p0", mem: 100), pod("p1", mem: 900)])
        let (unevenTypical, unevenPeak) = memoryRatios(uneven)
        assert(unevenTypical == 0.5)
        assert(unevenPeak == 0.9)
        let unevenNode = nodesForGraph(product: "mimir", components: [uneven], edges: []).first
        assert(unevenNode?.saturation == 0.5)
        assert(unevenNode?.peakReplicaSaturation == 0.9)
        assert(unevenNode?.detail == "50% typical · 90% peak of limit")
        assert(unevenNode?.level == .ok)   // peak 0.9 is under the limit, no OOM/throttle

        let overPeak = component("overpeak", memLimit: 1000, p99: 1100,
                                  pods: [pod("p0", mem: 100), pod("p1", mem: 1100)])
        let overPeakNode = nodesForGraph(product: "mimir", components: [overPeak], edges: []).first
        assert(overPeakNode?.level == .critical)   // one replica measured over its own limit, even though typical (0.6) is not

        // Genuine median vs mean divergence (3 replicas, odd count): the
        // mean of [100, 200, 900] is 400 (40%), but the median - the middle
        // value once sorted - is 200 (20%). Asserting 0.2, not 0.4, is what
        // actually proves this reads the median rather than quietly still
        // averaging under a new name.
        let threeReplicas = component("three", memLimit: 1000, p99: 900,
                                       pods: [pod("p0", mem: 100), pod("p1", mem: 200), pod("p2", mem: 900)])
        assert(memoryRatios(threeReplicas).typical == 0.2)

        // A peak within noise of typical is suppressed to nil rather than
        // reported - see `memoryRatios`'s own doc for why a tick sitting on
        // the fill it's meant to mark against would misread as a bug.
        // Exactly equal (both replicas measuring the same):
        let balanced = component("balanced", memLimit: 1000, p99: 500,
                                  pods: [pod("p0", mem: 500), pod("p1", mem: 500)])
        assert(memoryRatios(balanced).peak == nil)
        // Close enough to be noise, not a real spread:
        let nearBalanced = component("near-balanced", memLimit: 1000, p99: 505,
                                      pods: [pod("p0", mem: 500), pod("p1", mem: 505)])
        assert(memoryRatios(nearBalanced).peak == nil)

        // Saturation stays RAW past 100% - clamping happens only in the
        // renderer's own drawn fill, never at this producer (the bug class
        // this repo's CLAUDE.md documents: a "0...1 fill" doc comment
        // tempting a producer to clamp early, which silently turns a real
        // 198%-of-limit reading into a "100%" that looks fine). Single-pod
        // case here, so peak stays nil.
        let overLimit = component("mimir-distributor", product: "mimir", role: "distributor",
                                   title: "mimir/distributor", memLimit: 1000, p99: 1200)
        let overNode = nodesForGraph(product: "mimir", components: [overLimit], edges: []).first
        assert(overNode?.saturation == 1.2)   // NOT clamped to 1.0
        assert(overNode?.peakReplicaSaturation == nil)
        assert(overNode?.detail == "120% of limit")

        // A topology-expected node the report doesn't contain renders
        // present:false rather than being silently omitted - a gap in the
        // data path is itself worth seeing.
        let flowEdges = [LgtmFlowEdge(from: "mimir/distributor", to: "mimir/ingester", verb: "writes to"),
                          LgtmFlowEdge(from: "mimir/ingester", to: "mimir/querier", verb: "read by")]
        let onlyDistributor = component("mimir-distributor", product: "mimir", role: "distributor",
                                         title: "mimir/distributor", memLimit: 1000, p99: 100)
        let nodesByID = Dictionary(uniqueKeysWithValues:
            nodesForGraph(product: "mimir", components: [onlyDistributor], edges: flowEdges).map { ($0.id, $0) })
        assert(nodesByID["mimir/distributor"]?.present == true)
        assert(nodesByID["mimir/ingester"]?.present == false)   // expected via edges, no matching component
        assert(nodesByID["mimir/querier"]?.present == false)
        assert(nodesByID["mimir/querier"]?.level == .unknown)
        assert(nodesByID["mimir/querier"]?.saturation == nil)

        // podSuffix strips the component's own name, leaving the ordinal or
        // hash that actually distinguishes replicas.
        let named = component("mimir-ingester", memLimit: 1000, p99: 1)
        assert(podSuffix("mimir-ingester-0", component: named) == "0")
        assert(podSuffix("something-else", component: named) == "something-else")

        // podCountNote: only fires when the window's measured pod count
        // differs from today's replica count - not a guess at WHY.
        let churned = component("mimir-querier", memLimit: 1000, p99: 100, replicas: 2,
                                 pods: [pod("a", mem: 10), pod("b", mem: 10), pod("c", mem: 10)])
        assert(podCountNote(churned) != nil)
        let steady = component("mimir-ingester", memLimit: 1000, p99: 100, replicas: 1,
                                pods: [pod("a", mem: 10)])
        assert(podCountNote(steady) == nil)

        // spreadNote: a real gap reports a ratio; a single replica or
        // near-identical replicas report nothing.
        assert(spreadNote(usage(100, pods: [pod("a", mem: 100), pod("b", mem: 200)])) != nil)
        assert(spreadNote(usage(100, pods: [pod("a", mem: 100)])) == nil)
    }
}
#endif
