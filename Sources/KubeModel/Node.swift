import Foundation

public struct NodeList: Decodable {
    public let items: [Node]
}

public struct Node: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let status: NodeStatus?

    public var id: String { metadata.name }
    public var name: String { metadata.name }

    public var readyCondition: String {
        guard let c = status?.conditions?.first(where: { $0.type == "Ready" }) else { return "Unknown" }
        return c.status == "True" ? "Ready" : "NotReady"
    }

    public var kubeletVersion: String { status?.nodeInfo?.kubeletVersion ?? "-" }
    public var os: String { status?.nodeInfo?.osImage ?? "-" }

    public var cpuCapacityMillicores: Double {
        ResourceParser.cpuToMillicores(status?.capacity?["cpu"] ?? "0")
    }
    public var memoryCapacityBytes: Double {
        ResourceParser.memoryToBytes(status?.capacity?["memory"] ?? "0")
    }
    public var cpuAllocatableMillicores: Double {
        ResourceParser.cpuToMillicores(status?.allocatable?["cpu"] ?? "0")
    }
    public var memoryAllocatableBytes: Double {
        ResourceParser.memoryToBytes(status?.allocatable?["memory"] ?? "0")
    }

    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

public struct NodeStatus: Decodable, Hashable {
    public let conditions: [NodeCondition]?
    public let nodeInfo: NodeInfo?
    public let capacity: [String: String]?
    public let allocatable: [String: String]?
}

public struct NodeCondition: Decodable, Hashable {
    public let type: String
    public let status: String
}

public struct NodeInfo: Decodable, Hashable {
    public let kubeletVersion: String
    public let osImage: String
}
