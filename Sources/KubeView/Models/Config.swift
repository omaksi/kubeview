import Foundation

// MARK: - Secrets

struct SecretList: Decodable { let items: [Secret] }

struct Secret: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let type: String?
    let data: [String: String]?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var keys: [String] { (data ?? [:]).keys.sorted() }
    var sizeBytes: Int {
        (data ?? [:]).values.reduce(0) { $0 + (Data(base64Encoded: $1)?.count ?? 0) }
    }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
    func decoded(_ key: String) -> String? {
        guard let b64 = data?[key], let d = Data(base64Encoded: b64) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

// MARK: - Service Account (and IRSA)

struct ServiceAccountList: Decodable { let items: [ServiceAccount] }

struct ServiceAccount: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let automountServiceAccountToken: Bool?
    let secrets: [ObjectReference]?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var annotations: [String: String] { metadataAnnotations }
    var irsaRoleArn: String? {
        // `eks.amazonaws.com/role-arn` — decoded via the custom annotation path below.
        return metadata.annotations?["eks.amazonaws.com/role-arn"]
    }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
    private var metadataAnnotations: [String: String] { metadata.annotations ?? [:] }
}

// MARK: - ConfigMap

struct ConfigMapList: Decodable { let items: [ConfigMap] }

struct ConfigMap: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let data: [String: String]?
    let binaryData: [String: String]?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var textKeys: [String] { (data ?? [:]).keys.sorted() }
    var binaryKeys: [String] { (binaryData ?? [:]).keys.sorted() }
    var sizeBytes: Int {
        let text = (data ?? [:]).values.reduce(0) { $0 + $1.utf8.count }
        let bin = (binaryData ?? [:]).values.reduce(0) { $0 + (Data(base64Encoded: $1)?.count ?? 0) }
        return text + bin
    }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}
