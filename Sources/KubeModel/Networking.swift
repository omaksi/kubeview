import Foundation

// MARK: - Network Policy

public struct NetworkPolicyList: Decodable { public let items: [NetworkPolicy] }

public struct NetworkPolicy: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let spec: NetworkPolicySpec?
    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var policyTypes: [String] { spec?.policyTypes ?? [] }
    public var podSelector: [String: String] { spec?.podSelector?.matchLabels ?? [:] }
    public var ingressRuleCount: Int { spec?.ingress?.count ?? 0 }
    public var egressRuleCount: Int { spec?.egress?.count ?? 0 }
    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

public struct NetworkPolicySpec: Decodable, Hashable {
    public let podSelector: LabelSelector?
    public let policyTypes: [String]?
    public let ingress: [NetworkPolicyIngressRule]?
    public let egress: [NetworkPolicyEgressRule]?
}

public struct NetworkPolicyIngressRule: Decodable, Hashable {
    public let from: [NetworkPolicyPeer]?
    public let ports: [NetworkPolicyPort]?
}

public struct NetworkPolicyEgressRule: Decodable, Hashable {
    public let to: [NetworkPolicyPeer]?
    public let ports: [NetworkPolicyPort]?
}

public struct NetworkPolicyPeer: Decodable, Hashable {
    public let podSelector: LabelSelector?
    public let namespaceSelector: LabelSelector?
    public let ipBlock: IPBlock?
}

public struct IPBlock: Decodable, Hashable {
    public let cidr: String
    public let except: [String]?
}

public struct NetworkPolicyPort: Decodable, Hashable {
    public let port: StringOrInt?
    public let `protocol`: String?
    public enum CodingKeys: String, CodingKey {
        case port
        case `protocol` = "protocol"
    }
}

// MARK: - Services

public struct ServiceList: Decodable { public let items: [Service] }

public struct Service: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let spec: ServiceSpec?
    public let status: ServiceStatus?

    public init(metadata: ObjectMeta, spec: ServiceSpec?, status: ServiceStatus?) {
        self.metadata = metadata
        self.spec = spec
        self.status = status
    }

    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var type: String { spec?.type ?? "ClusterIP" }
    public var clusterIP: String { spec?.clusterIP ?? "-" }
    public var ports: [ServicePort] { spec?.ports ?? [] }
    public var selector: [String: String] { spec?.selector ?? [:] }
    public var externalIPs: [String] {
        var out: [String] = []
        out.append(contentsOf: spec?.externalIPs ?? [])
        let lb = status?.loadBalancer?.ingress ?? []
        out.append(contentsOf: lb.compactMap { $0.ip ?? $0.hostname })
        return out
    }
    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

public struct ServiceSpec: Decodable, Hashable {
    public let type: String?
    public let clusterIP: String?
    public let ports: [ServicePort]?
    public let selector: [String: String]?
    public let externalIPs: [String]?

    public init(type: String?, clusterIP: String?, ports: [ServicePort]?,
                selector: [String: String]?, externalIPs: [String]?) {
        self.type = type
        self.clusterIP = clusterIP
        self.ports = ports
        self.selector = selector
        self.externalIPs = externalIPs
    }
}

public struct ServicePort: Decodable, Hashable {
    public let name: String?
    public let port: Int
    public let targetPort: StringOrInt?
    public let `protocol`: String?

    public enum CodingKeys: String, CodingKey {
        case name, port, targetPort
        case `protocol` = "protocol"
    }

    public var display: String {
        let proto = self.`protocol` ?? "TCP"
        var s = "\(port)/\(proto)"
        if let t = targetPort { s += " → \(t.display)" }
        return s
    }
}

public struct ServiceStatus: Decodable, Hashable { public let loadBalancer: IngressLoadBalancer? }

// MARK: - Ingress (networking.k8s.io/v1)

public struct IngressList: Decodable { public let items: [Ingress] }

public struct Ingress: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let spec: IngressSpec?
    public let status: IngressStatus?

    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var className: String { spec?.ingressClassName ?? "-" }
    public var hosts: [String] { (spec?.rules ?? []).compactMap { $0.host } }
    public var tlsHosts: Set<String> { Set((spec?.tls ?? []).flatMap { $0.hosts ?? [] }) }

    public var externalAddresses: [String] {
        (status?.loadBalancer?.ingress ?? []).compactMap { $0.ip ?? $0.hostname }
    }

    public var paths: [IngressPathSummary] {
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

    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

public struct IngressPathSummary: Hashable {
    public let host: String
    public let path: String
    public let pathType: String
    public let serviceName: String
    public let servicePort: String

    public init(host: String, path: String, pathType: String, serviceName: String, servicePort: String) {
        self.host = host
        self.path = path
        self.pathType = pathType
        self.serviceName = serviceName
        self.servicePort = servicePort
    }
}

public struct IngressSpec: Decodable, Hashable {
    public let ingressClassName: String?
    public let rules: [IngressRule]?
    public let tls: [IngressTLS]?
}

public struct IngressRule: Decodable, Hashable {
    public let host: String?
    public let http: IngressHTTP?
}

public struct IngressHTTP: Decodable, Hashable { public let paths: [IngressPath]? }

public struct IngressPath: Decodable, Hashable {
    public let path: String?
    public let pathType: String?
    public let backend: IngressBackend
}

public struct IngressBackend: Decodable, Hashable { public let service: IngressServiceBackend? }

public struct IngressServiceBackend: Decodable, Hashable {
    public let name: String
    public let port: IngressPort?
}

public struct IngressPort: Decodable, Hashable {
    public let number: Int?
    public let name: String?
    public var display: String {
        if let n = number { return String(n) }
        return name ?? "-"
    }
}

public struct IngressTLS: Decodable, Hashable { public let hosts: [String]? }

public struct IngressStatus: Decodable, Hashable { public let loadBalancer: IngressLoadBalancer? }

public struct IngressLoadBalancer: Decodable, Hashable { public let ingress: [IngressLBEntry]? }

public struct IngressLBEntry: Decodable, Hashable {
    public let ip: String?
    public let hostname: String?
}
