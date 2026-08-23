import Foundation

// MARK: - Namespaces

public struct NamespaceList: Decodable { public let items: [KubeNamespace] }

public struct KubeNamespace: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let status: NamespaceStatus?
    public var id: String { metadata.name }
    public var name: String { metadata.name }
    public var phase: String { status?.phase ?? "Active" }
    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

public struct NamespaceStatus: Decodable, Hashable { public let phase: String? }
