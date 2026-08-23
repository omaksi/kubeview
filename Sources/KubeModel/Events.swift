import Foundation

public struct EventList: Decodable { public let items: [KubeEvent] }

public struct KubeEvent: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let type: String?
    public let reason: String?
    public let message: String?
    public let count: Int?
    public let firstTimestamp: String?
    public let lastTimestamp: String?
    public let eventTime: String?
    public let involvedObject: InvolvedObject?
    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var namespace: String { metadata.namespace ?? "default" }
    public var when: String {
        let ts = lastTimestamp ?? firstTimestamp ?? eventTime ?? metadata.creationTimestamp ?? ""
        return ts.isEmpty ? "-" : Pod.formatAge(from: ts)
    }
}

public struct InvolvedObject: Decodable, Hashable {
    public let kind: String?
    public let name: String?
    public let namespace: String?
}
