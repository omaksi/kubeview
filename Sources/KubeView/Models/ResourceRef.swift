import Foundation

struct ResourceRef: Hashable {
    let kind: ResourceKind
    /// Namespace-scoped: "<ns>/<name>". Cluster-scoped: "<name>".
    let key: String
    var storageKey: String { "\(kind.rawValue):\(key)" }

    /// The resource's namespace, or nil for cluster-scoped kinds.
    var namespace: String? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? parts[0] : nil
    }

    /// The resource's name (without namespace prefix).
    var resourceName: String {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? parts[1] : key
    }

    static func namespace(_ name: String) -> ResourceRef { .init(kind: .namespace, key: name) }
    static func pod(_ ns: String, _ name: String) -> ResourceRef { .init(kind: .pod, key: "\(ns)/\(name)") }
    static func node(_ name: String) -> ResourceRef { .init(kind: .node, key: name) }
    static func service(_ ns: String, _ name: String) -> ResourceRef { .init(kind: .service, key: "\(ns)/\(name)") }
    static func ingress(_ ns: String, _ name: String) -> ResourceRef { .init(kind: .ingress, key: "\(ns)/\(name)") }
}
