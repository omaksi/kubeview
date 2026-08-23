import Foundation

public struct PodList: Decodable {
    public let items: [Pod]
}

public struct Pod: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let status: PodStatus?
    public let spec: PodSpec?

    public init(metadata: ObjectMeta, status: PodStatus?, spec: PodSpec?) {
        self.metadata = metadata
        self.status = status
        self.spec = spec
    }

    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var phase: String { status?.phase ?? "Unknown" }

    public var readyRatio: String {
        let total = spec?.containers.count ?? 0
        let ready = status?.containerStatuses?.filter { $0.ready }.count ?? 0
        return "\(ready)/\(total)"
    }

    public var restarts: Int {
        status?.containerStatuses?.reduce(0) { $0 + $1.restartCount } ?? 0
    }

    public enum Health: Hashable {
        case ok
        case pending
        case failing(reason: String)
    }

    /// Detects unhealthy container states that `phase` alone hides
    /// (ImagePullBackOff, CrashLoopBackOff, ErrImagePull, etc.).
    public var healthState: Health {
        if phase == "Succeeded" { return .ok }
        if phase == "Failed"   { return .failing(reason: status?.reason ?? "Failed") }

        let badReasons: Set<String> = [
            "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull",
            "CreateContainerConfigError", "InvalidImageName",
            "RunContainerError", "CreateContainerError", "ErrImageNeverPull"
        ]
        let allStatuses = (status?.containerStatuses ?? []) + (status?.initContainerStatuses ?? [])
        if let bad = allStatuses.compactMap({ $0.state?.waiting?.reason }).first(where: { badReasons.contains($0) }) {
            return .failing(reason: bad)
        }

        if phase == "Running" {
            let ready = (status?.containerStatuses ?? []).allSatisfy { $0.ready }
            return ready ? .ok : .pending
        }
        if phase == "Pending" { return .pending }
        return .ok
    }

    public var isFailing: Bool { if case .failing = healthState { return true } else { return false } }
    public var failureReason: String? { if case .failing(let r) = healthState { return r } else { return nil } }

    /// Linkerd injection is detected by the presence of a `linkerd-proxy` sidecar.
    public var isLinkerdMeshed: Bool {
        (spec?.containers ?? []).contains { $0.name == "linkerd-proxy" }
    }

    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Self.formatAge(from: ts)
    }

    public static func formatAge(from iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let date = f.date(from: iso) else { return "-" }
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        if s < 86400 { return "\(s/3600)h" }
        return "\(s/86400)d"
    }
}

public struct PodSpec: Decodable, Hashable {
    public let containers: [Container]
    public let initContainers: [Container]?
    public let nodeName: String?
    public let serviceAccountName: String?
    public let restartPolicy: String?
    public let priorityClassName: String?
}

public struct Container: Decodable, Hashable {
    public let name: String
    public let image: String
    public let ports: [ContainerPort]?
    public let resources: ResourceRequirements?
    public let command: [String]?
    public let args: [String]?
}

public struct ContainerPort: Decodable, Hashable {
    public let containerPort: Int
    public let name: String?
    public let `protocol`: String?
    public enum CodingKeys: String, CodingKey {
        case containerPort, name
        case `protocol` = "protocol"
    }
    public var display: String {
        let proto = self.`protocol` ?? "TCP"
        if let n = name { return "\(n):\(containerPort)/\(proto)" }
        return "\(containerPort)/\(proto)"
    }
}

public struct ResourceRequirements: Decodable, Hashable {
    public let requests: [String: String]?
    public let limits: [String: String]?
}

public struct PodStatus: Decodable, Hashable {
    public let phase: String?
    public let podIP: String?
    public let hostIP: String?
    public let startTime: String?
    public let qosClass: String?
    public let message: String?
    public let reason: String?
    public let conditions: [PodCondition]?
    public let containerStatuses: [ContainerStatus]?
    public let initContainerStatuses: [ContainerStatus]?
}

public struct PodCondition: Decodable, Hashable {
    public let type: String
    public let status: String
    public let reason: String?
    public let message: String?
    public let lastTransitionTime: String?
}

public struct ContainerStatus: Decodable, Hashable {
    public let name: String
    public let image: String?
    public let imageID: String?
    public let ready: Bool
    public let started: Bool?
    public let restartCount: Int
    public let state: ContainerState?
    public let lastState: ContainerState?

    public enum CodingKeys: String, CodingKey {
        case name, image, imageID, ready, started, restartCount, state, lastState
    }
}

public struct ContainerState: Decodable, Hashable {
    public let running: RunningState?
    public let waiting: WaitingState?
    public let terminated: TerminatedState?

    public var summary: String {
        if running != nil { return "Running" }
        if let w = waiting { return w.reason ?? "Waiting" }
        if let t = terminated { return t.reason ?? "Terminated" }
        return "-"
    }
    public var detail: String? {
        if let w = waiting { return w.message }
        if let t = terminated {
            var parts: [String] = []
            if let c = t.exitCode { parts.append("exit=\(c)") }
            if let s = t.signal { parts.append("signal=\(s)") }
            if let m = t.message { parts.append(m) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        return nil
    }
}

public struct RunningState: Decodable, Hashable { public let startedAt: String? }

public struct WaitingState: Decodable, Hashable { public let reason: String?; public let message: String? }

public struct TerminatedState: Decodable, Hashable {
    public let exitCode: Int?
    public let signal: Int?
    public let reason: String?
    public let message: String?
    public let startedAt: String?
    public let finishedAt: String?
}
