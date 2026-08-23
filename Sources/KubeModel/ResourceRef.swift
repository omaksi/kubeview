import Foundation

public struct ResourceRef: Hashable {
    public let kind: ResourceKind
    /// Namespace-scoped: "<ns>/<name>". Cluster-scoped: "<name>".
    public let key: String

    public init(kind: ResourceKind, key: String) {
        self.kind = kind
        self.key = key
    }

    public var storageKey: String { "\(kind.rawValue):\(key)" }

    /// The resource's namespace, or nil for cluster-scoped kinds.
    public var namespace: String? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? parts[0] : nil
    }

    /// The resource's name (without namespace prefix).
    public var resourceName: String {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? parts[1] : key
    }

    public static func namespace(_ name: String) -> ResourceRef { .init(kind: .namespace, key: name) }
    public static func pod(_ ns: String, _ name: String) -> ResourceRef { .init(kind: .pod, key: "\(ns)/\(name)") }
    public static func node(_ name: String) -> ResourceRef { .init(kind: .node, key: name) }
    public static func service(_ ns: String, _ name: String) -> ResourceRef { .init(kind: .service, key: "\(ns)/\(name)") }
    public static func ingress(_ ns: String, _ name: String) -> ResourceRef { .init(kind: .ingress, key: "\(ns)/\(name)") }
}
