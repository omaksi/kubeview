import Foundation

// MARK: - Metrics (metrics.k8s.io/v1beta1)

public struct NodeMetricsList: Decodable { public let items: [NodeMetrics] }

public struct NodeMetrics: Decodable, Hashable {
    public let metadata: ObjectMeta
    public let usage: [String: String]
    public var name: String { metadata.name }
    public var cpu: String { usage["cpu"] ?? "0" }
    public var memory: String { usage["memory"] ?? "0" }
}

public struct PodMetricsList: Decodable { public let items: [PodMetrics] }

public struct PodMetrics: Decodable, Hashable {
    public let metadata: ObjectMeta
    public let containers: [ContainerMetrics]?
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var cpuMillicores: Double {
        (containers ?? []).reduce(0.0) { $0 + ResourceParser.cpuToMillicores($1.usage["cpu"] ?? "0") }
    }
    public var memoryBytes: Double {
        (containers ?? []).reduce(0.0) { $0 + ResourceParser.memoryToBytes($1.usage["memory"] ?? "0") }
    }
}

public struct ContainerMetrics: Decodable, Hashable {
    public let name: String
    public let usage: [String: String]
}
