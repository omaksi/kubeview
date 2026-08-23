import Foundation

// MARK: - Network Policy

struct NetworkPolicyList: Decodable { let items: [NetworkPolicy] }

struct NetworkPolicy: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let spec: NetworkPolicySpec?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var policyTypes: [String] { spec?.policyTypes ?? [] }
    var podSelector: [String: String] { spec?.podSelector?.matchLabels ?? [:] }
    var ingressRuleCount: Int { spec?.ingress?.count ?? 0 }
    var egressRuleCount: Int { spec?.egress?.count ?? 0 }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct NetworkPolicySpec: Decodable, Hashable {
    let podSelector: LabelSelector?
    let policyTypes: [String]?
    let ingress: [NetworkPolicyIngressRule]?
    let egress: [NetworkPolicyEgressRule]?
}

struct NetworkPolicyIngressRule: Decodable, Hashable {
    let from: [NetworkPolicyPeer]?
    let ports: [NetworkPolicyPort]?
}

struct NetworkPolicyEgressRule: Decodable, Hashable {
    let to: [NetworkPolicyPeer]?
    let ports: [NetworkPolicyPort]?
}

struct NetworkPolicyPeer: Decodable, Hashable {
    let podSelector: LabelSelector?
    let namespaceSelector: LabelSelector?
    let ipBlock: IPBlock?
}

struct IPBlock: Decodable, Hashable {
    let cidr: String
    let except: [String]?
}

struct NetworkPolicyPort: Decodable, Hashable {
    let port: StringOrInt?
    let `protocol`: String?
    enum CodingKeys: String, CodingKey {
        case port
        case `protocol` = "protocol"
    }
}

// MARK: - Services

struct ServiceList: Decodable { let items: [Service] }

struct Service: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let spec: ServiceSpec?
    let status: ServiceStatus?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var type: String { spec?.type ?? "ClusterIP" }
    var clusterIP: String { spec?.clusterIP ?? "-" }
    var ports: [ServicePort] { spec?.ports ?? [] }
    var selector: [String: String] { spec?.selector ?? [:] }
    var externalIPs: [String] {
        var out: [String] = []
        out.append(contentsOf: spec?.externalIPs ?? [])
        let lb = status?.loadBalancer?.ingress ?? []
        out.append(contentsOf: lb.compactMap { $0.ip ?? $0.hostname })
        return out
    }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct ServiceSpec: Decodable, Hashable {
    let type: String?
    let clusterIP: String?
    let ports: [ServicePort]?
    let selector: [String: String]?
    let externalIPs: [String]?
}

struct ServicePort: Decodable, Hashable {
    let name: String?
    let port: Int
    let targetPort: StringOrInt?
    let `protocol`: String?

    enum CodingKeys: String, CodingKey {
        case name, port, targetPort
        case `protocol` = "protocol"
    }

    var display: String {
        let proto = self.`protocol` ?? "TCP"
        var s = "\(port)/\(proto)"
        if let t = targetPort { s += " → \(t.display)" }
        return s
    }
}

struct ServiceStatus: Decodable, Hashable { let loadBalancer: IngressLoadBalancer? }

// MARK: - Ingress (networking.k8s.io/v1)

struct IngressList: Decodable { let items: [Ingress] }

struct Ingress: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let spec: IngressSpec?
    let status: IngressStatus?

    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var className: String { spec?.ingressClassName ?? "-" }
    var hosts: [String] { (spec?.rules ?? []).compactMap { $0.host } }
    var tlsHosts: Set<String> { Set((spec?.tls ?? []).flatMap { $0.hosts ?? [] }) }

    var externalAddresses: [String] {
        (status?.loadBalancer?.ingress ?? []).compactMap { $0.ip ?? $0.hostname }
    }

    var paths: [IngressPathSummary] {
        (spec?.rules ?? []).flatMap { rule -> [IngressPathSummary] in
            (rule.http?.paths ?? []).map { p in
                IngressPathSummary(
                    host: rule.host ?? "*",
                    path: p.path ?? "/",
                    pathType: p.pathType ?? "Prefix",
                    serviceName: p.backend.service?.name ?? "-",
                    servicePort: p.backend.service?.port?.display ?? "-"
                )
            }
        }
    }

    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct IngressPathSummary: Hashable {
    let host: String
    let path: String
    let pathType: String
    let serviceName: String
    let servicePort: String
}

struct IngressSpec: Decodable, Hashable {
    let ingressClassName: String?
    let rules: [IngressRule]?
    let tls: [IngressTLS]?
}

struct IngressRule: Decodable, Hashable {
    let host: String?
    let http: IngressHTTP?
}

struct IngressHTTP: Decodable, Hashable { let paths: [IngressPath]? }

struct IngressPath: Decodable, Hashable {
    let path: String?
    let pathType: String?
    let backend: IngressBackend
}

struct IngressBackend: Decodable, Hashable { let service: IngressServiceBackend? }

struct IngressServiceBackend: Decodable, Hashable {
    let name: String
    let port: IngressPort?
}

struct IngressPort: Decodable, Hashable {
    let number: Int?
    let name: String?
    var display: String {
        if let n = number { return String(n) }
        return name ?? "-"
    }
}

struct IngressTLS: Decodable, Hashable { let hosts: [String]? }

struct IngressStatus: Decodable, Hashable { let loadBalancer: IngressLoadBalancer? }

struct IngressLoadBalancer: Decodable, Hashable { let ingress: [IngressLBEntry]? }

struct IngressLBEntry: Decodable, Hashable {
    let ip: String?
    let hostname: String?
}
