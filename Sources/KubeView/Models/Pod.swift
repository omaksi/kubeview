import Foundation

struct PodList: Decodable {
    let items: [Pod]
}

struct Pod: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let status: PodStatus?
    let spec: PodSpec?

    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var phase: String { status?.phase ?? "Unknown" }

    var readyRatio: String {
        let total = spec?.containers.count ?? 0
        let ready = status?.containerStatuses?.filter { $0.ready }.count ?? 0
        return "\(ready)/\(total)"
    }

    var restarts: Int {
        status?.containerStatuses?.reduce(0) { $0 + $1.restartCount } ?? 0
    }

    enum Health: Hashable {
        case ok
        case pending
        case failing(reason: String)
    }

    /// Detects unhealthy container states that `phase` alone hides
    /// (ImagePullBackOff, CrashLoopBackOff, ErrImagePull, etc.).
    var healthState: Health {
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

    var isFailing: Bool { if case .failing = healthState { return true } else { return false } }
    var failureReason: String? { if case .failing(let r) = healthState { return r } else { return nil } }

    /// Linkerd injection is detected by the presence of a `linkerd-proxy` sidecar.
    var isLinkerdMeshed: Bool {
        (spec?.containers ?? []).contains { $0.name == "linkerd-proxy" }
    }

    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Self.formatAge(from: ts)
    }

    static func formatAge(from iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let date = f.date(from: iso) else { return "-" }
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        if s < 86400 { return "\(s/3600)h" }
        return "\(s/86400)d"
    }
}

struct PodSpec: Decodable, Hashable {
    let containers: [Container]
    let initContainers: [Container]?
    let nodeName: String?
    let serviceAccountName: String?
    let restartPolicy: String?
    let priorityClassName: String?
}

struct Container: Decodable, Hashable {
    let name: String
    let image: String
    let ports: [ContainerPort]?
    let resources: ResourceRequirements?
    let command: [String]?
    let args: [String]?
}

struct ContainerPort: Decodable, Hashable {
    let containerPort: Int
    let name: String?
    let `protocol`: String?
    enum CodingKeys: String, CodingKey {
        case containerPort, name
        case `protocol` = "protocol"
    }
    var display: String {
        let proto = self.`protocol` ?? "TCP"
        if let n = name { return "\(n):\(containerPort)/\(proto)" }
        return "\(containerPort)/\(proto)"
    }
}

struct ResourceRequirements: Decodable, Hashable {
    let requests: [String: String]?
    let limits: [String: String]?
}

struct PodStatus: Decodable, Hashable {
    let phase: String?
    let podIP: String?
    let hostIP: String?
    let startTime: String?
    let qosClass: String?
    let message: String?
    let reason: String?
    let conditions: [PodCondition]?
    let containerStatuses: [ContainerStatus]?
    let initContainerStatuses: [ContainerStatus]?
}

struct PodCondition: Decodable, Hashable {
    let type: String
    let status: String
    let reason: String?
    let message: String?
    let lastTransitionTime: String?
}

struct ContainerStatus: Decodable, Hashable {
    let name: String
    let image: String?
    let imageID: String?
    let ready: Bool
    let started: Bool?
    let restartCount: Int
    let state: ContainerState?
    let lastState: ContainerState?

    enum CodingKeys: String, CodingKey {
        case name, image, imageID, ready, started, restartCount, state, lastState
    }
}

struct ContainerState: Decodable, Hashable {
    let running: RunningState?
    let waiting: WaitingState?
    let terminated: TerminatedState?

    var summary: String {
        if running != nil { return "Running" }
        if let w = waiting { return w.reason ?? "Waiting" }
        if let t = terminated { return t.reason ?? "Terminated" }
        return "-"
    }
    var detail: String? {
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

struct RunningState: Decodable, Hashable { let startedAt: String? }

struct WaitingState: Decodable, Hashable { let reason: String?; let message: String? }

struct TerminatedState: Decodable, Hashable {
    let exitCode: Int?
    let signal: Int?
    let reason: String?
    let message: String?
    let startedAt: String?
    let finishedAt: String?
}
