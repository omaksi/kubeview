import Foundation

// MARK: - Persistent Volume Claim

struct PVCList: Decodable { let items: [PVC] }

struct PVC: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let spec: PVCSpec?
    let status: PVCStatus?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var storageClass: String { spec?.storageClassName ?? "-" }
    var volumeName: String { spec?.volumeName ?? "-" }
    var accessModes: [String] { spec?.accessModes ?? [] }
    var phase: String { status?.phase ?? "Unknown" }
    var capacity: String { status?.capacity?["storage"] ?? spec?.resources?.requests?["storage"] ?? "-" }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct PVCSpec: Decodable, Hashable {
    let storageClassName: String?
    let volumeName: String?
    let accessModes: [String]?
    let resources: ResourceRequirements?
}

struct PVCStatus: Decodable, Hashable {
    let phase: String?
    let capacity: [String: String]?
}

// MARK: - Storage Class

struct StorageClassList: Decodable { let items: [StorageClass] }

struct StorageClass: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let provisioner: String?
    let reclaimPolicy: String?
    let volumeBindingMode: String?
    let allowVolumeExpansion: Bool?
    var id: String { metadata.name }
    var name: String { metadata.name }
    var isDefault: Bool {
        metadata.annotations?["storageclass.kubernetes.io/is-default-class"] == "true" ||
        metadata.annotations?["storageclass.beta.kubernetes.io/is-default-class"] == "true"
    }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}
