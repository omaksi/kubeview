import SwiftUI

// Architectural knowledge about the Grafana LGTM stack itself - the data path
// each product's Helm chart wires up - not about any particular cluster. A
// static table is right for that: the shape of mimir-distributed's write
// path doesn't change when a cluster scales an ingester up or down, only
// whether the node showing it is `present`.
//
// Verified against a live 30-component `inno-shared-eks` install
// (kubectl-lgtm --json --no-metrics) rather than guessed - see the per-role
// comments below for where the real cluster disagreed with the obvious
// assumption.

/// Where a component sits in a product's data path. Read and write are the two
/// directions that matter for spotting a bottleneck; the others exist so they
/// can be drawn out of the way rather than confused for the hot path.
enum LgtmLane: String, CaseIterable {
    case write, read, cache, maintenance, standalone
}

/// One directed hop in a product's data path, between two node ids.
struct LgtmFlowEdge: Hashable {
    let from: String
    let to: String
    /// Reads as a sentence between the two labels: "distributor *writes to* ingester".
    let verb: String
}

/// How loaded a node is, for colouring. Kept separate from the finding severity
/// so the Cluster tab (which has no findings) can still say "this one is hot".
enum LgtmNodeLevel {
    case unknown, ok, warn, critical
}

/// A node handed to the renderer. Both tabs build these from their own data -
/// the Cluster tab from live pod state, the Metrics tab from usage history.
struct LgtmGraphNode: Identifiable, Hashable {
    /// Matches `LgtmComponent.title`, which is unique per report by invariant.
    let id: String
    let label: String
    /// One short line under the label: "3/3 ready" or "1.7Gi p99".
    let detail: String
    let lane: LgtmLane
    let level: LgtmNodeLevel
    /// A raw ratio (used / ceiling) - NOT pre-clamped to 0...1, and callers
    /// must not clamp it before handing it over. A component with no CPU
    /// limit measured against its request, or one genuinely over its limit,
    /// legitimately reads above 1.0 (mimir/store-gateway measured live at
    /// 1.976). Nil when there's nothing to saturate against. The renderer
    /// clamps this for drawing (bar width, tick position) but never for the
    /// number it prints - this is a map, not a verdict, and a value that's
    /// been rounded down to "100%" before it ever reaches the view is a
    /// verdict wearing a measurement's clothes.
    let saturation: Double?
    /// The single busiest replica's own saturation - a raw ratio on the same
    /// scale as `saturation`, also not pre-clamped, for the same reason. Nil
    /// when there's one replica, the caller hasn't computed one, or
    /// `saturation` already represents the busiest replica itself. Lets the
    /// graph mark "one copy is doing all the work" separately from whatever
    /// `saturation` represents (real spread measured live: mimir/querier
    /// 1.99x busiest/quietest across 6 pods, mimir/ingester 1.02x - the
    /// unevenness varies by an order of magnitude across the stack, which is
    /// exactly what this field exists to surface). `var` with a default, not
    /// `let`: a stored `let` with a default value is dropped from the
    /// synthesized memberwise init entirely, which would leave both calling
    /// views unable to pass it.
    var peakReplicaSaturation: Double? = nil
    /// False when the topology expects this role but the cluster has no such
    /// workload - a gap in the data path is itself worth seeing.
    let present: Bool
}

enum LgtmTopology {
    /// The data path for one product, as node ids and the hops between them.
    /// Node ids are `product/role`, matching `LgtmComponent.title` - except
    /// where they aren't: Alloy and Grafana components report an empty
    /// `role` from kubectl-lgtm's classifier (verified live: `product=alloy
    /// role=[] title=alloy`, `title=alloy-metrics`, `title=alloy-singleton`;
    /// `product=grafana role=[] title=grafana`), so their titles - and the
    /// node ids here - are the bare workload name, no slash.
    static func edges(for product: String) -> [LgtmFlowEdge] {
        switch product {
        case "mimir":   return Mimir.edges + Cross.all.filter { touches($0, prefix: "mimir/") }
        case "loki":    return Loki.edges + Cross.all.filter { touches($0, prefix: "loki/") }
        case "tempo":   return Tempo.edges + Cross.all.filter { touches($0, prefix: "tempo/") }
        case "alloy":   return Cross.alloyEdges
        case "grafana": return Cross.grafanaEdges
        default:        return []
        }
    }

    private static func touches(_ edge: LgtmFlowEdge, prefix: String) -> Bool {
        edge.from.hasPrefix(prefix) || edge.to.hasPrefix(prefix)
    }

    /// Which lane a role belongs to. Driven by role alone wherever possible -
    /// kubectl-lgtm normalises role names across products (every one of
    /// mimir/loki/tempo's four caches classifies as role "memcached", not a
    /// per-product cache name), so a single switch over the verified live
    /// role strings covers all three products at once.
    static func lane(product: String, role: String) -> LgtmLane {
        switch (product, role) {
        case (_, "ingester"), (_, "distributor"): return .write
        // The front door for both directions at once - see the `nginx`/
        // `gateway` edges below, which fan out to both the write and read
        // chains from this one node. Pinned to `.write` rather than split;
        // there's no lane that means "both", and write is where every one
        // of these products' own docs lists it first.
        case (_, "gateway"), (_, "nginx"): return .write
        case ("alloy", ""): return .write

        case (_, "querier"), (_, "query-frontend"), (_, "query-scheduler"): return .read
        case (_, "store-gateway"), (_, "index-gateway"): return .read
        case ("grafana", ""): return .read
        case (_, "read"): return .read              // Loki simple-scalable/monolithic shape, lane-only - see Loki.edges

        case (_, "memcached"): return .cache

        case (_, "compactor"), (_, "ruler"), (_, "alertmanager"), (_, "overrides-exporter"): return .maintenance
        case (_, "backend"): return .maintenance     // Loki simple-scalable shape, lane-only

        case (_, "write"): return .write             // Loki simple-scalable shape, lane-only
        // A monolithic process is every lane at once; "standalone" reads
        // truer than arbitrarily picking one.
        case (_, "all"), (_, "single-binary"): return .standalone

        default: return .standalone
        }
    }

    /// Products this topology knows the shape of, in the order they should be
    /// drawn. A product not listed here still renders, just without edges.
    /// Mirrors `LgtmClusterView.knownProducts`' ordering (minus pyroscope,
    /// which kubectl-lgtm doesn't classify today - `default: return []`
    /// already handles it exactly like any other unknown product).
    static let known: [String] = ["mimir", "loki", "tempo", "alloy", "grafana"]

    // MARK: - Per-product data paths

    private enum Mimir {
        static let edges: [LgtmFlowEdge] = [
            LgtmFlowEdge(from: "mimir/nginx", to: "mimir/distributor", verb: "routes writes to"),
            LgtmFlowEdge(from: "mimir/distributor", to: "mimir/ingester", verb: "ships samples to"),
            // Not a live push - the ingester periodically flushes blocks to
            // object storage and the compactor picks them up from there.
            // Drawn as a hop anyway: that's still the data's path, just with
            // S3 as an invisible middleman no K8s workload represents.
            LgtmFlowEdge(from: "mimir/ingester", to: "mimir/compactor", verb: "flushes blocks for"),
            LgtmFlowEdge(from: "mimir/compactor", to: "mimir/store-gateway", verb: "hands blocks to"),

            LgtmFlowEdge(from: "mimir/nginx", to: "mimir/query-frontend", verb: "routes queries to"),
            LgtmFlowEdge(from: "mimir/query-frontend", to: "mimir/query-scheduler", verb: "queues via"),
            LgtmFlowEdge(from: "mimir/query-scheduler", to: "mimir/querier", verb: "dispatches to"),
            LgtmFlowEdge(from: "mimir/querier", to: "mimir/ingester", verb: "reads recent series from"),
            LgtmFlowEdge(from: "mimir/querier", to: "mimir/store-gateway", verb: "reads blocks from"),

            LgtmFlowEdge(from: "mimir/query-frontend", to: "mimir/results-cache", verb: "caches results in"),
            LgtmFlowEdge(from: "mimir/store-gateway", to: "mimir/chunks-cache", verb: "caches chunks in"),
            LgtmFlowEdge(from: "mimir/store-gateway", to: "mimir/index-cache", verb: "caches index in"),
            LgtmFlowEdge(from: "mimir/store-gateway", to: "mimir/metadata-cache", verb: "caches metadata in"),

            LgtmFlowEdge(from: "mimir/ruler", to: "mimir/query-frontend", verb: "evaluates rules via"),
            LgtmFlowEdge(from: "mimir/ruler", to: "mimir/distributor", verb: "writes rule results to"),
            LgtmFlowEdge(from: "mimir/ruler", to: "mimir/alertmanager", verb: "sends alerts to"),
            // overrides-exporter has no edges here on purpose - it exports
            // per-tenant limit config as metrics for Grafana/alerting to
            // read, it doesn't sit on the write or read path itself.
        ]
    }

    private enum Loki {
        // gateway/distributor/ingester/querier/query-frontend verified live;
        // compactor and index-gateway are real loki-distributed roles this
        // particular install just doesn't run (no compaction workload
        // deployed) - exactly the "gap worth seeing" case `present` exists
        // for, so they stay in the table.
        static let edges: [LgtmFlowEdge] = [
            LgtmFlowEdge(from: "loki/gateway", to: "loki/distributor", verb: "routes writes to"),
            LgtmFlowEdge(from: "loki/distributor", to: "loki/ingester", verb: "ships streams to"),
            LgtmFlowEdge(from: "loki/ingester", to: "loki/compactor", verb: "flushes chunks for"),
            LgtmFlowEdge(from: "loki/compactor", to: "loki/index-gateway", verb: "publishes index to"),

            LgtmFlowEdge(from: "loki/gateway", to: "loki/query-frontend", verb: "routes queries to"),
            LgtmFlowEdge(from: "loki/query-frontend", to: "loki/querier", verb: "dispatches to"),
            LgtmFlowEdge(from: "loki/querier", to: "loki/ingester", verb: "reads recent chunks from"),
            LgtmFlowEdge(from: "loki/querier", to: "loki/index-gateway", verb: "reads index from"),
        ]
        // ponytail: the simple-scalable/monolithic shape (`read`/`write`/
        // `backend`/`all`/`single-binary` targets, which collapse the roles
        // above into one-to-three processes) isn't wired into this edge
        // list - `lane(product:role:)` classifies those role strings
        // correctly, but they aren't chained into a graph here. Ceiling:
        // `edges(for:)` only ever sees the product name, not which shape a
        // given cluster deployed, and the two shapes' node sets are
        // mutually exclusive in practice - modelling both here would mean
        // every microservices install (the only shape seen live) shows a
        // second, permanently-absent phantom sub-graph next to the real
        // one. Upgrade path: this would need a signature that can see which
        // roles are actually live, which is a caller-side change outside
        // this file's lane.
    }

    private enum Tempo {
        static let edges: [LgtmFlowEdge] = [
            LgtmFlowEdge(from: "tempo/distributor", to: "tempo/ingester", verb: "ships spans to"),
            LgtmFlowEdge(from: "tempo/ingester", to: "tempo/compactor", verb: "flushes blocks for"),

            LgtmFlowEdge(from: "tempo/query-frontend", to: "tempo/querier", verb: "dispatches to"),
            LgtmFlowEdge(from: "tempo/querier", to: "tempo/ingester", verb: "reads recent traces from"),
            LgtmFlowEdge(from: "tempo/querier", to: "tempo/memcached", verb: "caches lookups in"),
            // Deliberately no gateway and no store-gateway node, contrary to
            // the Mimir-shaped assumption: verified live, tempo-distributed
            // has neither. Clients push straight to the distributor over
            // per-protocol receivers (OTLP/Jaeger/Zipkin - each just a port
            // on that one Deployment, not a separate component
            // kubectl-lgtm would ever classify), and the querier reads
            // older blocks straight from object storage - there's no
            // Mimir-style proxying tier in front of it.
        ]
    }

    // MARK: - Cross-product edges

    /// Where the stack's data actually starts and ends, as opposed to every
    /// edge above which describes a product moving data it already has.
    private enum Cross {
        /// Alloy is the single most interesting edge on the page: it's the
        /// only family here that shows data entering the stack at all. All
        /// three flavours (DaemonSet log/node-metrics collector, StatefulSet
        /// clustered-metrics collector, Deployment singleton-job collector)
        /// are modelled identically, fanning into every ingestion product's
        /// distributor - kubectl-lgtm's own classifier doesn't disambiguate
        /// them either (role is "" for all three; only the title differs),
        /// and their real per-flavour routing lives in Alloy's River config,
        /// which this app never parses.
        static let alloyNodes = ["alloy", "alloy-metrics", "alloy-singleton"]
        static let alloyEdges: [LgtmFlowEdge] = alloyNodes.flatMap { a in
            [
                LgtmFlowEdge(from: a, to: "mimir/distributor", verb: "remote-writes metrics to"),
                LgtmFlowEdge(from: a, to: "loki/distributor", verb: "ships logs to"),
                LgtmFlowEdge(from: a, to: "tempo/distributor", verb: "forwards traces to"),
            ]
        }

        /// The other end of the funnel: every dashboard/Explore query goes
        /// out through each product's query-frontend - the entry point each
        /// one fronts with a queue/cache/fan-out layer - not the ingest side.
        static let grafanaEdges: [LgtmFlowEdge] = [
            LgtmFlowEdge(from: "grafana", to: "mimir/query-frontend", verb: "queries"),
            LgtmFlowEdge(from: "grafana", to: "loki/query-frontend", verb: "queries"),
            LgtmFlowEdge(from: "grafana", to: "tempo/query-frontend", verb: "queries"),
        ]

        static let all: [LgtmFlowEdge] = alloyEdges + grafanaEdges
    }
}

// MARK: - Self-check

#if DEBUG
/// Covers the two pieces of non-trivial pure logic this file owns: that
/// `lane(product:role:)` gives every role string actually seen on a live
/// 30-component cluster (plus the collapsed Loki shape this table doesn't
/// wire into edges) the classification this file intends, and that the edge
/// tables - hand-written data, the easiest place to typo a node id into one
/// that never matches a real `LgtmComponent.title` - are internally
/// consistent: no self-loops, no cycles (the real topologies are DAGs), and
/// the cross-product edges actually land where the Alloy/Grafana comment
/// above claims they do.
extension LgtmTopology {
    static func selfCheck() {
        assert(known == ["mimir", "loki", "tempo", "alloy", "grafana"])
        assert(edges(for: "pyroscope").isEmpty, "an unclassified product must render without edges, not crash")

        // Lane assignment against every (product, role) pair actually
        // observed on inno-shared-eks (kubectl-lgtm --json --no-metrics,
        // 2026-08-21), plus the collapsed-target roles this file classifies
        // but doesn't chain into edges.
        let observed: [(String, String, LgtmLane)] = [
            ("mimir", "nginx", .write), ("mimir", "distributor", .write), ("mimir", "ingester", .write),
            ("mimir", "compactor", .maintenance), ("mimir", "store-gateway", .read),
            ("mimir", "query-frontend", .read), ("mimir", "query-scheduler", .read), ("mimir", "querier", .read),
            ("mimir", "ruler", .maintenance), ("mimir", "alertmanager", .maintenance),
            ("mimir", "overrides-exporter", .maintenance), ("mimir", "memcached", .cache),
            ("loki", "gateway", .write), ("loki", "distributor", .write), ("loki", "ingester", .write),
            ("loki", "querier", .read), ("loki", "query-frontend", .read),
            ("tempo", "distributor", .write), ("tempo", "ingester", .write), ("tempo", "compactor", .maintenance),
            ("tempo", "querier", .read), ("tempo", "query-frontend", .read), ("tempo", "memcached", .cache),
            ("alloy", "", .write), ("grafana", "", .read),
            ("loki", "read", .read), ("loki", "write", .write), ("loki", "backend", .maintenance),
            ("loki", "all", .standalone), ("loki", "single-binary", .standalone),
        ]
        for (product, role, expected) in observed {
            assert(lane(product: product, role: role) == expected,
                   "lane(\(product), \(role)) should be \(expected)")
        }
        assert(lane(product: "unknown-product", role: "unknown-role") == .standalone, "unrecognised roles must fall back, not crash")

        func hasCycle(_ edges: [LgtmFlowEdge]) -> Bool {
            var adjacency: [String: [String]] = [:]
            for e in edges { adjacency[e.from, default: []].append(e.to) }
            var visiting: Set<String> = [], visited: Set<String> = []
            func dfs(_ id: String) -> Bool {
                if visiting.contains(id) { return true }
                if visited.contains(id) { return false }
                visiting.insert(id)
                for next in adjacency[id] ?? [] where dfs(next) { return true }
                visiting.remove(id)
                visited.insert(id)
                return false
            }
            return adjacency.keys.contains { dfs($0) }
        }

        for product in known {
            let e = edges(for: product)
            assert(!e.isEmpty, "\(product) is in `known` but has no edges")
            assert(!e.contains { $0.from == $0.to }, "\(product) has a self-loop")
            assert(!hasCycle(e), "\(product)'s data path must be a DAG")
        }

        // The cross-product wiring the comments above promise, both
        // directions: Alloy's own graph fans out to every product, and each
        // product's own graph shows Alloy feeding it and Grafana reading it.
        let alloyOut = edges(for: "alloy")
        assert(alloyOut.contains { $0.from == "alloy" && $0.to == "mimir/distributor" })
        assert(alloyOut.contains { $0.from == "alloy" && $0.to == "loki/distributor" })
        assert(alloyOut.contains { $0.from == "alloy" && $0.to == "tempo/distributor" })
        assert(edges(for: "mimir").contains { $0.from == "alloy" && $0.to == "mimir/distributor" })
        assert(edges(for: "mimir").contains { $0.from == "grafana" && $0.to == "mimir/query-frontend" })
        assert(edges(for: "grafana").contains { $0.from == "grafana" && $0.to == "loki/query-frontend" })
    }
}
#endif
