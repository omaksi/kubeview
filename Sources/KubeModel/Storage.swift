import Foundation

// MARK: - Persistent Volume Claim

public struct PVCList: Decodable { public let items: [PVC] }

public struct PVC: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let spec: PVCSpec?
    public let status: PVCStatus?
    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var storageClass: String { spec?.storageClassName ?? "-" }
    public var volumeName: String { spec?.volumeName ?? "-" }
    public var accessModes: [String] { spec?.accessModes ?? [] }
    public var phase: String { status?.phase ?? "Unknown" }
    public var capacity: String { status?.capacity?["storage"] ?? spec?.resources?.requests?["storage"] ?? "-" }
    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

public struct PVCSpec: Decodable, Hashable {
    public let storageClassName: String?
    public let volumeName: String?
    public let accessModes: [String]?
    public let resources: ResourceRequirements?
}

public struct PVCStatus: Decodable, Hashable {
    public let phase: String?
    public let capacity: [String: String]?
}

// MARK: - Storage Class

public struct StorageClassList: Decodable { public let items: [StorageClass] }

public struct StorageClass: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let provisioner: String?
    public let reclaimPolicy: String?
    public let volumeBindingMode: String?
    public let allowVolumeExpansion: Bool?
    public var id: String { metadata.name }
    public var name: String { metadata.name }
    public var isDefault: Bool {
        metadata.annotations?["storageclass.kubernetes.io/is-default-class"] == "true" ||
        metadata.annotations?["storageclass.beta.kubernetes.io/is-default-class"] == "true"
    }
    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}
