import Foundation

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
