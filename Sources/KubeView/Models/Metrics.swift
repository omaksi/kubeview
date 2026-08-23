import Foundation

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
