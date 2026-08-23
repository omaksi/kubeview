import Foundation

struct KubeContext: Identifiable, Hashable {
    let name: String
    var id: String { name }
}

struct ObjectMeta: Decodable, Hashable {
    let name: String
    let namespace: String?
    let creationTimestamp: String?
    let labels: [String: String]?
    let annotations: [String: String]?
    /// Both come free with every `kubectl get -o json` the app already makes —
    /// they were simply being dropped on decode. No extra call for the graph.
    let uid: String?
    let ownerReferences: [OwnerReference]?
}

struct OwnerReference: Decodable, Hashable {
    let uid: String
    let kind: String
    let name: String
    let controller: Bool?
}

struct LabelSelector: Decodable, Hashable {
    let matchLabels: [String: String]?
}

struct ObjectReference: Decodable, Hashable {
    let name: String?
    let namespace: String?
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
