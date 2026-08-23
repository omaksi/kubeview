import Foundation

// MARK: - Secrets

public struct SecretList: Decodable { public let items: [Secret] }

public struct Secret: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let type: String?
    public let data: [String: String]?
    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var keys: [String] { (data ?? [:]).keys.sorted() }
    public var sizeBytes: Int {
        (data ?? [:]).values.reduce(0) { $0 + (Data(base64Encoded: $1)?.count ?? 0) }
    }
    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
    public func decoded(_ key: String) -> String? {
        guard let b64 = data?[key], let d = Data(base64Encoded: b64) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

// MARK: - Service Account (and IRSA)

public struct ServiceAccountList: Decodable { public let items: [ServiceAccount] }

public struct ServiceAccount: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let automountServiceAccountToken: Bool?
    public let secrets: [ObjectReference]?
    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var annotations: [String: String] { metadataAnnotations }
    public var irsaRoleArn: String? {
        // `eks.amazonaws.com/role-arn` — decoded via the custom annotation path below.
        return metadata.annotations?["eks.amazonaws.com/role-arn"]
    }
    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
    private var metadataAnnotations: [String: String] { metadata.annotations ?? [:] }
}

// MARK: - ConfigMap

public struct ConfigMapList: Decodable { public let items: [ConfigMap] }

public struct ConfigMap: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let data: [String: String]?
    public let binaryData: [String: String]?
    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var textKeys: [String] { (data ?? [:]).keys.sorted() }
    public var binaryKeys: [String] { (binaryData ?? [:]).keys.sorted() }
    public var sizeBytes: Int {
        let text = (data ?? [:]).values.reduce(0) { $0 + $1.utf8.count }
        let bin = (binaryData ?? [:]).values.reduce(0) { $0 + (Data(base64Encoded: $1)?.count ?? 0) }
        return text + bin
    }
    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}
