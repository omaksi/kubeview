import Foundation

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
    var namespace: String { metadata.namespace ?? "default" }
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
