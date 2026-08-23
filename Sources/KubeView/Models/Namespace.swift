import Foundation

// MARK: - Namespaces

struct NamespaceList: Decodable { let items: [Namespace] }

struct Namespace: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let status: NamespaceStatus?
    var id: String { metadata.name }
    var name: String { metadata.name }
    var phase: String { status?.phase ?? "Active" }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct NamespaceStatus: Decodable, Hashable { let phase: String? }
