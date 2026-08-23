import Foundation

// A namespace's resources as a directed graph: ownership (Deployment →
// ReplicaSet → Pod, CronJob → Job → Pod), Service → Pod selector matches,
// Ingress → Service, HPA → its scale target. Pure — no SwiftUI, no I/O — so
// `selfCheck` is the whole test story.

struct GraphNode: Identifiable, Hashable {
    let uid: String
    let kind: ResourceKind
    let ref: ResourceRef
    let label: String
    let detail: String
    let healthy: Bool
    /// How many siblings this node stands in for; 0 for a real resource.
    let collapsedCount: Int
    /// The owner whose children were collapsed, for the expand toggle.
    let collapsesOwner: String?
    var column = 0
    var row = 0

    var id: String { uid }
    var isAggregate: Bool { collapsedCount > 0 }
}

/// Why two resources are connected. An arrow on its own is ambiguous —
/// "Service → Pod" and "ReplicaSet → Pod" mean very different things, and
/// only one of them is ownership.
enum EdgeRelation: String, Hashable, CaseIterable {
    case owns, selects, routes, scales, collapsed

    /// Reads as a sentence between the two node labels: "ReplicaSet *owns* Pod".
    var label: String {
        switch self {
        case .owns:      return "owns"
        case .selects:   return "selects"
        case .routes:    return "routes to"
        case .scales:    return "scales"
        case .collapsed: return "more"
        }
    }

    var legend: String {
        switch self {
        case .owns:      return "owns (ownerReference)"
        case .selects:   return "selects (label selector)"
        case .routes:    return "routes to"
        case .scales:    return "scales"
        case .collapsed: return "hidden replicas"
        }
    }
}

struct GraphEdge: Hashable {
    let from: String
    let to: String
    /// Defaulted so the ownership case — by far the most common — stays terse
    /// at its five call sites.
    var relation: EdgeRelation = .owns
}

enum ResourceGraph {
    /// Pods past this many under one owner collapse into a single "+N more".
    /// Same idea as NamespaceCard listing 3 unhealthy workloads then a count:
    /// a 200-pod DaemonSet is noise, not information.
    static let fanOutCap = 15

    // ponytail: a static tier table, not a layering algorithm. Ceiling: an edge
    // that runs backwards (an owner kind we don't model, e.g. a Rollout CRD)
    // would draw right-to-left. Upgrade path is longest-path layering off the
    // edge list — every edge we build today already runs left to right.
    static func column(_ kind: ResourceKind) -> Int {
        switch kind {
        case .ingress:                                        return 0
        case .service, .hpa:                                  return 1
        case .deployment, .statefulSet, .daemonSet, .cronJob: return 2
        case .replicaSet, .job:                               return 3
        case .pod:                                            return 4
        default:                                              return 2
        }
    }

    /// Slices are expected to be namespace-scoped already — the caller has the
    /// namespace, this doesn't.
    static func build(
        pods: [Pod], services: [Service], ingresses: [Ingress],
        deployments: [Deployment], statefulSets: [StatefulSet], daemonSets: [DaemonSet],
        replicaSets: [ReplicaSet], jobs: [KubeJob], cronJobs: [CronJob], hpas: [HPA],
        expanded: Set<String> = []
    ) -> (nodes: [GraphNode], edges: [GraphEdge]) {
        var nodes: [GraphNode] = []
        var owners: [String: [String]] = [:]
        var byKindName: [String: String] = [:]   // "Deployment/web" → uid, for HPA targets

        // No uid means no ownership resolution. Every `kubectl get -o json`
        // sets one, so an absent uid is a decode bug rather than cluster state.
        func add(_ meta: ObjectMeta, _ kind: ResourceKind, _ detail: String, _ healthy: Bool) {
            guard let uid = meta.uid else { return }
            let ref = ResourceRef(kind: kind, key: "\(meta.namespace ?? "-")/\(meta.name)")
            nodes.append(GraphNode(uid: uid, kind: kind, ref: ref, label: meta.name,
                                   detail: detail, healthy: healthy,
                                   collapsedCount: 0, collapsesOwner: nil))
            let parents = (meta.ownerReferences ?? []).map(\.uid)
            if !parents.isEmpty { owners[uid] = parents }
            byKindName["\(kind.title)/\(meta.name)"] = uid
        }

        for i in ingresses    { add(i.metadata, .ingress, i.className, true) }
        for s in services     { add(s.metadata, .service, s.type, true) }
        for h in hpas         { add(h.metadata, .hpa, "\(h.currentReplicas)/\(h.maxReplicas)", true) }
        for d in deployments  { add(d.metadata, .deployment, "\(d.ready)/\(d.desired)", d.isHealthy) }
        for s in statefulSets { add(s.metadata, .statefulSet, "\(s.ready)/\(s.desired)", s.isHealthy) }
        for d in daemonSets   { add(d.metadata, .daemonSet, "\(d.ready)/\(d.desired)", d.isHealthy) }
        for c in cronJobs     { add(c.metadata, .cronJob, c.schedule, true) }
        // A ReplicaSet scaled to zero with nothing running is rollout history,
        // not topology — every past revision would otherwise show up forever.
        for r in replicaSets where r.desired > 0 || (r.status?.replicas ?? 0) > 0 {
            add(r.metadata, .replicaSet, "\(r.ready)/\(r.desired)", r.isHealthy)
        }
        for j in jobs { add(j.metadata, .job, "\(j.succeeded)/\(j.completions)", j.isHealthy) }
        for p in pods { add(p.metadata, .pod, p.failureReason ?? p.phase, !p.isFailing) }

        // Ownership. Iterating `nodes` rather than the dictionary keeps edge
        // order deterministic, which keeps the layout stable across refreshes.
        let known = Set(nodes.map(\.uid))
        var edges: [GraphEdge] = []
        for n in nodes {
            for parent in owners[n.uid] ?? [] where known.contains(parent) {
                edges.append(GraphEdge(from: parent, to: n.uid))
            }
        }

        // Fan-out cap, applied per owner and only to pods.
        var ownerOfPod: [String: String] = [:]
        let podUIDs = Set(nodes.filter { $0.kind == .pod }.map(\.uid))
        for e in edges where podUIDs.contains(e.to) { ownerOfPod[e.to] = e.from }
        var children: [String: [GraphNode]] = [:]
        for n in nodes where n.kind == .pod {
            if let owner = ownerOfPod[n.uid] { children[owner, default: []].append(n) }
        }
        var hidden: Set<String> = []
        var aggregates: [GraphNode] = []
        for owner in children.keys.sorted() {
            let kids = children[owner] ?? []
            guard kids.count > fanOutCap, !expanded.contains(owner) else { continue }
            // Unhealthy first, original order within each bucket — the same
            // "show what's broken, count the rest" the namespace cards use.
            let ordered = kids.enumerated().sorted {
                $0.element.healthy == $1.element.healthy ? $0.offset < $1.offset : !$0.element.healthy
            }.map(\.element)
            let dropped = ordered.dropFirst(fanOutCap)
            hidden.formUnion(dropped.map(\.uid))
            let uid = "more:\(owner)"
            aggregates.append(GraphNode(uid: uid, kind: .pod,
                                        ref: ResourceRef(kind: .pod, key: uid),
                                        label: "+\(dropped.count) more", detail: "pods",
                                        healthy: dropped.allSatisfy(\.healthy),
                                        collapsedCount: dropped.count, collapsesOwner: owner))
        }
        if !hidden.isEmpty {
            nodes = nodes.filter { !hidden.contains($0.uid) } + aggregates
            edges = edges.filter { !hidden.contains($0.from) && !hidden.contains($0.to) }
            edges += aggregates.map { GraphEdge(from: $0.collapsesOwner ?? "", to: $0.uid, relation: .collapsed) }
        }

        // Service → Pod by label-subset match, then Ingress → Service, then
        // HPA → scale target. All client-side over data already fetched.
        let live = Set(nodes.map(\.uid))
        for svc in services {
            guard let sid = svc.metadata.uid, live.contains(sid), !svc.selector.isEmpty else { continue }
            for pod in pods {
                guard let pid = pod.metadata.uid, live.contains(pid) else { continue }
                if matches(selector: svc.selector, labels: pod.metadata.labels) {
                    edges.append(GraphEdge(from: sid, to: pid, relation: .selects))
                }
            }
        }
        for ing in ingresses {
            guard let iid = ing.metadata.uid, live.contains(iid) else { continue }
            var seen: Set<String> = []
            for path in ing.paths where seen.insert(path.serviceName).inserted {
                if let sid = byKindName["Service/\(path.serviceName)"], live.contains(sid) {
                    edges.append(GraphEdge(from: iid, to: sid, relation: .routes))
                }
            }
        }
        for hpa in hpas {
            guard let hid = hpa.metadata.uid, live.contains(hid),
                  let target = byKindName["\(hpa.targetKind)/\(hpa.targetName)"],
                  live.contains(target) else { continue }
            edges.append(GraphEdge(from: hid, to: target, relation: .scales))
        }

        layout(&nodes, edges: edges)
        return (nodes, edges)
    }

    static func matches(selector: [String: String], labels: [String: String]?) -> Bool {
        guard !selector.isEmpty else { return false }
        return selector.allSatisfy { labels?[$0.key] == $0.value }
    }

    /// Tiered columns plus one barycenter pass: each node is ordered by the
    /// mean row of its already-placed parents. Enough to uncross the shapes a
    /// namespace actually produces; deliberately not a crossing minimiser.
    static func layout(_ nodes: inout [GraphNode], edges: [GraphEdge]) {
        guard !nodes.isEmpty else { return }
        var parents: [String: [String]] = [:]
        for e in edges { parents[e.to, default: []].append(e.from) }
        var rowOf: [String: Int] = [:]
        let maxColumn = nodes.map { column($0.kind) }.max() ?? 0
        for c in 0...maxColumn {
            let inColumn = nodes.indices.filter { column(nodes[$0].kind) == c }
            let ordered = inColumn.enumerated().sorted { a, b in
                let ba = barycenter(nodes[a.element].uid, parents, rowOf)
                let bb = barycenter(nodes[b.element].uid, parents, rowOf)
                return ba == bb ? a.offset < b.offset : ba < bb   // stable: ties keep input order
            }.map(\.element)
            for (row, idx) in ordered.enumerated() {
                nodes[idx].column = c
                nodes[idx].row = row
                rowOf[nodes[idx].uid] = row
            }
        }
        // Close up unused columns, so a namespace with no ingresses doesn't
        // render a blank gutter where column 0 would have been.
        let used = Set(nodes.map(\.column)).sorted()
        let dense = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($1, $0) })
        for i in nodes.indices { nodes[i].column = dense[nodes[i].column] ?? 0 }
    }

    /// Parentless nodes sink to the bottom of their column rather than
    /// interleaving with nodes that have a reason to be where they are.
    private static func barycenter(_ uid: String, _ parents: [String: [String]],
                                   _ rowOf: [String: Int]) -> Double {
        let rows = (parents[uid] ?? []).compactMap { rowOf[$0] }
        guard !rows.isEmpty else { return .greatestFiniteMagnitude }
        return Double(rows.reduce(0, +)) / Double(rows.count)
    }

    #if DEBUG
    /// Runs once, from `NamespaceGraphView.init`. Not called from `build` —
    /// `selfCheck` calls `build`, and a static-let-once that re-enters itself
    /// deadlocks.
    static let selfCheckOnce: Void = { selfCheck() }()

    private static func meta(_ name: String, _ uid: String, owner: (String, String)? = nil,
                             labels: [String: String]? = nil) -> ObjectMeta {
        ObjectMeta(name: name, namespace: "ns", creationTimestamp: nil, labels: labels,
                   annotations: nil, uid: uid,
                   ownerReferences: owner.map {
                       [OwnerReference(uid: $0.0, kind: $0.1, name: "-", controller: true)]
                   })
    }

    static func selfCheck() {
        let dep = Deployment(metadata: meta("web", "d1"), spec: nil, status: nil)
        let rs = ReplicaSet(metadata: meta("web-abc", "r1", owner: ("d1", "Deployment")),
                            spec: ReplicaSetSpec(replicas: 1, selector: nil), status: nil)
        let pod = Pod(metadata: meta("web-abc-1", "p1", owner: ("r1", "ReplicaSet"),
                                     labels: ["app": "web", "pod-template-hash": "abc"]),
                      status: nil, spec: nil)
        let other = Pod(metadata: meta("api-1", "p2", labels: ["app": "api"]), status: nil, spec: nil)
        let svc = Service(metadata: meta("web", "s1"),
                          spec: ServiceSpec(type: "ClusterIP", clusterIP: "10.0.0.1", ports: nil,
                                            selector: ["app": "web"], externalIPs: nil),
                          status: nil)

        let g = build(pods: [pod, other], services: [svc], ingresses: [], deployments: [dep],
                      statefulSets: [], daemonSets: [], replicaSets: [rs], jobs: [], cronJobs: [],
                      hpas: [])
        assert(g.edges.contains(GraphEdge(from: "d1", to: "r1")), "ownerReferences: Deployment → ReplicaSet")
        assert(g.edges.contains(GraphEdge(from: "r1", to: "p1")), "ownerReferences: ReplicaSet → Pod")
        assert(g.edges.contains(GraphEdge(from: "s1", to: "p1", relation: .selects)), "selector is a subset of the pod's labels")
        assert(!g.edges.contains(GraphEdge(from: "s1", to: "p2", relation: .selects)), "selector must not match another app")
        let depColumn = g.nodes.first { $0.uid == "d1" }?.column ?? -1
        let rsColumn = g.nodes.first { $0.uid == "r1" }?.column ?? -1
        let podColumn = g.nodes.first { $0.uid == "p1" }?.column ?? -1
        assert(depColumn < rsColumn && rsColumn < podColumn, "owners must sit left of what they own")
        assert(depColumn == 1, "columns are made dense — with no ingress, Service takes column 0")

        assert(matches(selector: ["app": "web"], labels: ["app": "web", "tier": "x"]))
        assert(!matches(selector: ["app": "web", "tier": "y"], labels: ["app": "web"]))
        assert(!matches(selector: [:], labels: ["app": "web"]), "an empty selector selects nothing")

        let many = (0..<20).map {
            Pod(metadata: meta("web-\($0)", "m\($0)", owner: ("r1", "ReplicaSet")), status: nil, spec: nil)
        }
        let capped = build(pods: many, services: [], ingresses: [], deployments: [dep],
                           statefulSets: [], daemonSets: [], replicaSets: [rs], jobs: [],
                           cronJobs: [], hpas: [])
        let shown = capped.nodes.filter { $0.kind == .pod && !$0.isAggregate }
        assert(shown.count == fanOutCap, "fan-out cap not applied")
        assert(capped.nodes.first { $0.isAggregate }?.collapsedCount == many.count - fanOutCap)
        assert(capped.edges.contains(GraphEdge(from: "r1", to: "more:r1", relation: .collapsed)))

        let all = build(pods: many, services: [], ingresses: [], deployments: [dep],
                        statefulSets: [], daemonSets: [], replicaSets: [rs], jobs: [],
                        cronJobs: [], hpas: [], expanded: ["r1"])
        assert(all.nodes.filter { $0.kind == .pod }.count == many.count, "expanding must show every pod")
    }
    #endif
}
