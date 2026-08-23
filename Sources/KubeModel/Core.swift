import Foundation

public struct KubeContext: Identifiable, Hashable {
    public let name: String
    public var id: String { name }
    public init(name: String) {
        self.name = name
    }
}

public struct ObjectMeta: Decodable, Hashable {
    public let name: String
    public let namespace: String?
    public let creationTimestamp: String?
    public let labels: [String: String]?
    public let annotations: [String: String]?
    /// Both come free with every `kubectl get -o json` the app already makes —
    /// they were simply being dropped on decode. No extra call for the graph.
    public let uid: String?
    public let ownerReferences: [OwnerReference]?

    public init(name: String, namespace: String?, creationTimestamp: String?,
                labels: [String: String]?, annotations: [String: String]?,
                uid: String?, ownerReferences: [OwnerReference]?) {
        self.name = name
        self.namespace = namespace
        self.creationTimestamp = creationTimestamp
        self.labels = labels
        self.annotations = annotations
        self.uid = uid
        self.ownerReferences = ownerReferences
    }
}

public struct OwnerReference: Decodable, Hashable {
    public let uid: String
    public let kind: String
    public let name: String
    public let controller: Bool?

    public init(uid: String, kind: String, name: String, controller: Bool?) {
        self.uid = uid
        self.kind = kind
        self.name = name
        self.controller = controller
    }
}

public struct LabelSelector: Decodable, Hashable {
    public let matchLabels: [String: String]?
}

public struct ObjectReference: Decodable, Hashable {
    public let name: String?
    public let namespace: String?
}

public enum StringOrInt: Decodable, Hashable {
    case int(Int)
    case string(String)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        self = .string(try c.decode(String.self))
    }
    public var display: String {
        switch self {
        case .int(let i): return String(i)
        case .string(let s): return s
        }
    }
}
