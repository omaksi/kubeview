import Foundation

struct KubeContext: Identifiable, Hashable {
    let name: String
    var id: String { name }
}

struct PodList: Decodable {
    let items: [Pod]
}

struct Pod: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let status: PodStatus?
    let spec: PodSpec?

    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var phase: String { status?.phase ?? "Unknown" }

    var readyRatio: String {
        let total = spec?.containers.count ?? 0
        let ready = status?.containerStatuses?.filter { $0.ready }.count ?? 0
        return "\(ready)/\(total)"
    }

    var restarts: Int {
        status?.containerStatuses?.reduce(0) { $0 + $1.restartCount } ?? 0
    }

    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Self.formatAge(from: ts)
    }

    static func formatAge(from iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let date = f.date(from: iso) else { return "-" }
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        if s < 86400 { return "\(s/3600)h" }
        return "\(s/86400)d"
    }
}

struct ObjectMeta: Decodable, Hashable {
    let name: String
    let namespace: String?
    let creationTimestamp: String?
}

struct PodSpec: Decodable, Hashable {
    let containers: [Container]
    let initContainers: [Container]?
    let nodeName: String?
    let serviceAccountName: String?
    let restartPolicy: String?
    let priorityClassName: String?
}

struct Container: Decodable, Hashable {
    let name: String
    let image: String
    let ports: [ContainerPort]?
    let resources: ResourceRequirements?
    let command: [String]?
    let args: [String]?
}

struct ContainerPort: Decodable, Hashable {
    let containerPort: Int
    let name: String?
    let `protocol`: String?
    enum CodingKeys: String, CodingKey {
        case containerPort, name
        case `protocol` = "protocol"
    }
    var display: String {
        let proto = self.`protocol` ?? "TCP"
        if let n = name { return "\(n):\(containerPort)/\(proto)" }
        return "\(containerPort)/\(proto)"
    }
}

struct ResourceRequirements: Decodable, Hashable {
    let requests: [String: String]?
    let limits: [String: String]?
}

struct PodStatus: Decodable, Hashable {
    let phase: String?
    let podIP: String?
    let hostIP: String?
    let startTime: String?
    let qosClass: String?
    let message: String?
    let reason: String?
    let conditions: [PodCondition]?
    let containerStatuses: [ContainerStatus]?
    let initContainerStatuses: [ContainerStatus]?
}

struct PodCondition: Decodable, Hashable {
    let type: String
    let status: String
    let reason: String?
    let message: String?
    let lastTransitionTime: String?
}

struct ContainerStatus: Decodable, Hashable {
    let name: String
    let image: String?
    let imageID: String?
    let ready: Bool
    let started: Bool?
    let restartCount: Int
    let state: ContainerState?
    let lastState: ContainerState?

    enum CodingKeys: String, CodingKey {
        case name, image, imageID, ready, started, restartCount, state, lastState
    }
}

struct ContainerState: Decodable, Hashable {
    let running: RunningState?
    let waiting: WaitingState?
    let terminated: TerminatedState?

    var summary: String {
        if running != nil { return "Running" }
        if let w = waiting { return w.reason ?? "Waiting" }
        if let t = terminated { return t.reason ?? "Terminated" }
        return "-"
    }
    var detail: String? {
        if let w = waiting { return w.message }
        if let t = terminated {
            var parts: [String] = []
            if let c = t.exitCode { parts.append("exit=\(c)") }
            if let s = t.signal { parts.append("signal=\(s)") }
            if let m = t.message { parts.append(m) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        return nil
    }
}

struct RunningState: Decodable, Hashable { let startedAt: String? }
struct WaitingState: Decodable, Hashable { let reason: String?; let message: String? }
struct TerminatedState: Decodable, Hashable {
    let exitCode: Int?
    let signal: Int?
    let reason: String?
    let message: String?
    let startedAt: String?
    let finishedAt: String?
}

struct NodeList: Decodable {
    let items: [Node]
}

struct Node: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let status: NodeStatus?

    var id: String { metadata.name }
    var name: String { metadata.name }

    var readyCondition: String {
        guard let c = status?.conditions?.first(where: { $0.type == "Ready" }) else { return "Unknown" }
        return c.status == "True" ? "Ready" : "NotReady"
    }

    var kubeletVersion: String { status?.nodeInfo?.kubeletVersion ?? "-" }
    var os: String { status?.nodeInfo?.osImage ?? "-" }

    var cpuCapacityMillicores: Double {
        ResourceParser.cpuToMillicores(status?.capacity?["cpu"] ?? "0")
    }
    var memoryCapacityBytes: Double {
        ResourceParser.memoryToBytes(status?.capacity?["memory"] ?? "0")
    }
    var cpuAllocatableMillicores: Double {
        ResourceParser.cpuToMillicores(status?.allocatable?["cpu"] ?? "0")
    }
    var memoryAllocatableBytes: Double {
        ResourceParser.memoryToBytes(status?.allocatable?["memory"] ?? "0")
    }

    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct NodeStatus: Decodable, Hashable {
    let conditions: [NodeCondition]?
    let nodeInfo: NodeInfo?
    let capacity: [String: String]?
    let allocatable: [String: String]?
}

struct NodeCondition: Decodable, Hashable {
    let type: String
    let status: String
}

struct NodeInfo: Decodable, Hashable {
    let kubeletVersion: String
    let osImage: String
}

// MARK: - Namespaces

struct NamespaceList: Decodable { let items: [Namespace] }

struct Namespace: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let status: NamespaceStatus?
    var id: String { metadata.name }
    var name: String { metadata.name }
    var phase: String { status?.phase ?? "Active" }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct NamespaceStatus: Decodable, Hashable { let phase: String? }

// MARK: - Events

struct EventList: Decodable { let items: [KubeEvent] }

struct KubeEvent: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let type: String?
    let reason: String?
    let message: String?
    let count: Int?
    let firstTimestamp: String?
    let lastTimestamp: String?
    let eventTime: String?
    let involvedObject: InvolvedObject?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var when: String {
        let ts = lastTimestamp ?? firstTimestamp ?? eventTime ?? metadata.creationTimestamp ?? ""
        return ts.isEmpty ? "-" : Pod.formatAge(from: ts)
    }
}

struct InvolvedObject: Decodable, Hashable {
    let kind: String?
    let name: String?
    let namespace: String?
}

// MARK: - Services

struct ServiceList: Decodable { let items: [Service] }

struct Service: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let spec: ServiceSpec?
    let status: ServiceStatus?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var type: String { spec?.type ?? "ClusterIP" }
    var clusterIP: String { spec?.clusterIP ?? "-" }
    var ports: [ServicePort] { spec?.ports ?? [] }
    var selector: [String: String] { spec?.selector ?? [:] }
    var externalIPs: [String] {
        var out: [String] = []
        out.append(contentsOf: spec?.externalIPs ?? [])
        let lb = status?.loadBalancer?.ingress ?? []
        out.append(contentsOf: lb.compactMap { $0.ip ?? $0.hostname })
        return out
    }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct ServiceSpec: Decodable, Hashable {
    let type: String?
    let clusterIP: String?
    let ports: [ServicePort]?
    let selector: [String: String]?
    let externalIPs: [String]?
}

struct ServicePort: Decodable, Hashable {
    let name: String?
    let port: Int
    let targetPort: StringOrInt?
    let `protocol`: String?

    enum CodingKeys: String, CodingKey {
        case name, port, targetPort
        case `protocol` = "protocol"
    }

    var display: String {
        let proto = self.`protocol` ?? "TCP"
        var s = "\(port)/\(proto)"
        if let t = targetPort { s += " → \(t.display)" }
        return s
    }
}

enum StringOrInt: Decodable, Hashable {
    case int(Int)
    case string(String)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        self = .string(try c.decode(String.self))
    }
    var display: String {
        switch self {
        case .int(let i): return String(i)
        case .string(let s): return s
        }
    }
}

struct ServiceStatus: Decodable, Hashable { let loadBalancer: IngressLoadBalancer? }

// MARK: - Ingress (networking.k8s.io/v1)

struct IngressList: Decodable { let items: [Ingress] }

struct Ingress: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let spec: IngressSpec?
    let status: IngressStatus?

    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var className: String { spec?.ingressClassName ?? "-" }
    var hosts: [String] { (spec?.rules ?? []).compactMap { $0.host } }
    var tlsHosts: Set<String> { Set((spec?.tls ?? []).flatMap { $0.hosts ?? [] }) }

    var externalAddresses: [String] {
        (status?.loadBalancer?.ingress ?? []).compactMap { $0.ip ?? $0.hostname }
    }

    var paths: [IngressPathSummary] {
        (spec?.rules ?? []).flatMap { rule -> [IngressPathSummary] in
            (rule.http?.paths ?? []).map { p in
                IngressPathSummary(
                    host: rule.host ?? "*",
                    path: p.path ?? "/",
                    pathType: p.pathType ?? "Prefix",
                    serviceName: p.backend.service?.name ?? "-",
                    servicePort: p.backend.service?.port?.display ?? "-"
                )
            }
        }
    }

    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct IngressPathSummary: Hashable {
    let host: String
    let path: String
    let pathType: String
    let serviceName: String
    let servicePort: String
}

struct IngressSpec: Decodable, Hashable {
    let ingressClassName: String?
    let rules: [IngressRule]?
    let tls: [IngressTLS]?
}

struct IngressRule: Decodable, Hashable {
    let host: String?
    let http: IngressHTTP?
}

struct IngressHTTP: Decodable, Hashable { let paths: [IngressPath]? }

struct IngressPath: Decodable, Hashable {
    let path: String?
    let pathType: String?
    let backend: IngressBackend
}

struct IngressBackend: Decodable, Hashable { let service: IngressServiceBackend? }

struct IngressServiceBackend: Decodable, Hashable {
    let name: String
    let port: IngressPort?
}

struct IngressPort: Decodable, Hashable {
    let number: Int?
    let name: String?
    var display: String {
        if let n = number { return String(n) }
        return name ?? "-"
    }
}

struct IngressTLS: Decodable, Hashable { let hosts: [String]? }

struct IngressStatus: Decodable, Hashable { let loadBalancer: IngressLoadBalancer? }

struct IngressLoadBalancer: Decodable, Hashable { let ingress: [IngressLBEntry]? }

struct IngressLBEntry: Decodable, Hashable {
    let ip: String?
    let hostname: String?
}

// MARK: - Metrics (metrics.k8s.io/v1beta1)

struct NodeMetricsList: Decodable { let items: [NodeMetrics] }

struct NodeMetrics: Decodable, Hashable {
    let metadata: ObjectMeta
    let usage: [String: String]
    var name: String { metadata.name }
    var cpu: String { usage["cpu"] ?? "0" }
    var memory: String { usage["memory"] ?? "0" }
}

struct PodMetricsList: Decodable { let items: [PodMetrics] }

struct PodMetrics: Decodable, Hashable {
    let metadata: ObjectMeta
    let containers: [ContainerMetrics]?
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var cpuMillicores: Double {
        (containers ?? []).reduce(0.0) { $0 + ResourceParser.cpuToMillicores($1.usage["cpu"] ?? "0") }
    }
    var memoryBytes: Double {
        (containers ?? []).reduce(0.0) { $0 + ResourceParser.memoryToBytes($1.usage["memory"] ?? "0") }
    }
}

struct ContainerMetrics: Decodable, Hashable {
    let name: String
    let usage: [String: String]
}

// MARK: - Resource parsing

enum ResourceParser {
    /// Convert CPU quantity ("500m", "1", "100u", "100n") to millicores.
    static func cpuToMillicores(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        if s.hasSuffix("n") { return (Double(s.dropLast()) ?? 0) / 1_000_000 }
        if s.hasSuffix("u") { return (Double(s.dropLast()) ?? 0) / 1_000 }
        if s.hasSuffix("m") { return Double(s.dropLast()) ?? 0 }
        return (Double(s) ?? 0) * 1000
    }

    /// Convert memory quantity ("128Mi", "1Gi", "500M", "1024") to bytes.
    static func memoryToBytes(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        let units: [(String, Double)] = [
            ("Ki", 1024), ("Mi", 1024*1024), ("Gi", pow(1024,3)), ("Ti", pow(1024,4)), ("Pi", pow(1024,5)),
            ("K", 1000), ("M", 1_000_000), ("G", 1_000_000_000), ("T", 1e12), ("P", 1e15)
        ]
        for (suffix, mult) in units where s.hasSuffix(suffix) {
            if let n = Double(s.dropLast(suffix.count)) { return n * mult }
        }
        return Double(s) ?? 0
    }

    static func formatMillicores(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.2f", m / 1000) }
        return "\(Int(m))m"
    }

    static func formatBytes(_ b: Double) -> String {
        let g = 1024.0 * 1024 * 1024
        let mi = 1024.0 * 1024
        if b >= g { return String(format: "%.1f Gi", b / g) }
        if b >= mi { return String(format: "%.0f Mi", b / mi) }
        return String(format: "%.0f", b)
    }
}
