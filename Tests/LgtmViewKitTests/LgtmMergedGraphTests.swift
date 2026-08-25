import XCTest
@testable import LgtmViewKit

/// Pins the SHAPE the merged, vertical graph lays out to. `selfCheck` covers
/// the invariants (edges run down the page, a cycle terminates, nothing is
/// dropped); this covers the thing a reader actually notices, which is
/// whether the whole stack drawn at once is a legible column of tiers or one
/// enormous row. That distinction is a measurement, not an assertion about
/// correctness, so it belongs in a test with real numbers in it rather than
/// in an `assert`.
final class LgtmMergedGraphTests: XCTestCase {
    /// Every node the merged graph draws for a cluster running the full
    /// stack: both endpoints of every merged edge. Lane and level don't
    /// affect tiering, only slot tie-breaks, so a uniform stand-in is enough.
    private func mergedNodes() -> [LgtmGraphNode] {
        Set(LgtmTopology.allEdges.flatMap { [$0.from, $0.to] }).sorted().map { id in
            LgtmGraphNode(id: id, product: LgtmTopology.product(forNodeID: id), label: id,
                          detail: "", lane: .standalone, level: .unknown, saturation: nil, present: true)
        }
    }

    /// Tiering is a property of the edge table, not of which components a
    /// given cluster happens to run, so these numbers are the shape EVERY
    /// full-stack cluster gets. Against the reference `inno-shared-eks`
    /// install (mimir 11, loki 6, tempo 6, grafana 1, alloy 3 = 30
    /// components) that is 31 edge-connected nodes: the 28 of those 30 that
    /// sit on a modelled hop, plus loki/compactor and loki/index-gateway,
    /// which the topology expects and this install doesn't run.
    /// mimir/overrides-exporter is the odd one out - it has no edges at all
    /// (see `LgtmTopology.Mimir`), so it isn't an endpoint here; the shelf
    /// case below covers it.
    func test_mergedStack_isDeepNotWide() {
        let placed = LgtmGraphLayout.place(nodes: mergedNodes(), edges: LgtmTopology.allEdges)
        let tiers = (placed.map(\.tier).max() ?? 0) + 1
        let widest = (placed.map(\.slot).max() ?? 0) + 1

        XCTAssertEqual(placed.count, 31, "every endpoint of the merged edge table")
        XCTAssertEqual(tiers, 8, "the merged stack tiers down the page")
        XCTAssertEqual(widest, 7, "and stays narrower than it is deep, which is why it draws vertically")
        XCTAssertGreaterThan(tiers, widest, "a wider-than-deep graph would be the wrong way round for a vertical flow")
    }

    /// An edge-free component (mimir/overrides-exporter is the only real one)
    /// shelves onto a tier of its own AFTER the whole merged flow, rather
    /// than crowding tier 0 next to Alloy and the gateways, which is where a
    /// naive "no parents means it's a source" rule would put it.
    func test_mergedStack_shelvesEdgeFreeComponentsAtTheEnd() {
        let exporter = LgtmGraphNode(id: "mimir/overrides-exporter", product: "mimir",
                                     label: "overrides-exporter", detail: "", lane: .maintenance,
                                     level: .unknown, saturation: nil, present: true)
        let placed = LgtmGraphLayout.place(nodes: mergedNodes() + [exporter], edges: LgtmTopology.allEdges)
        let tier = Dictionary(uniqueKeysWithValues: placed.map { ($0.node.id, $0.tier) })
        let deepestConnected = placed.filter { $0.node.id != exporter.id }.map(\.tier).max() ?? 0
        XCTAssertEqual(tier[exporter.id], deepestConnected + 1)
        XCTAssertEqual((placed.map(\.tier).max() ?? 0) + 1, 9, "the full 30-component render is nine tiers deep")
    }

    /// Every tier is contiguous and every slot within a tier is unique -
    /// otherwise two chips would be drawn on top of each other, or the
    /// canvas would size itself around an empty gutter.
    func test_mergedStack_slotsAreDenseAndUnique() {
        let placed = LgtmGraphLayout.place(nodes: mergedNodes(), edges: LgtmTopology.allEdges)
        let byTier = Dictionary(grouping: placed, by: \.tier)
        XCTAssertEqual(Set(byTier.keys), Set(0..<byTier.count), "tiers must be contiguous from 0")
        for (tier, group) in byTier {
            let slots = group.map(\.slot).sorted()
            XCTAssertEqual(slots, Array(0..<group.count), "tier \(tier) must fill slots 0..<n exactly once each")
        }
    }

    /// Products are what the colour encoding tells apart, so each one has to
    /// actually be in the merged graph - a product silently contributing no
    /// nodes would render a legend swatch for nothing.
    func test_mergedStack_carriesEveryProduct() {
        let products = Set(mergedNodes().map(\.product))
        XCTAssertEqual(products, Set(LgtmTopology.known))
    }

    /// The seam the merge exists for: in five separate graphs each of these
    /// was a stub at both ends. Alloy is the only node family that shows data
    /// entering the stack at all, and Grafana the only one reading it out.
    func test_mergedStack_keepsCrossProductEdges() {
        let placed = LgtmGraphLayout.place(nodes: mergedNodes(), edges: LgtmTopology.allEdges)
        let tier = Dictionary(uniqueKeysWithValues: placed.map { ($0.node.id, $0.tier) })
        for alloy in ["alloy", "alloy-metrics", "alloy-singleton"] {
            for product in ["mimir", "loki", "tempo"] {
                XCTAssertLessThan(tier[alloy]!, tier["\(product)/distributor"]!,
                                  "\(alloy) must sit above \(product)/distributor")
            }
        }
        for product in ["mimir", "loki", "tempo"] {
            XCTAssertLessThan(tier["grafana"]!, tier["\(product)/query-frontend"]!,
                              "grafana must sit above \(product)/query-frontend")
        }
    }
}
