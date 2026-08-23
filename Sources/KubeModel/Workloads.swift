import Foundation

// MARK: - Workloads

public struct DeploymentList: Decodable { public let items: [Deployment] }

public struct Deployment: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let spec: DeploymentSpec?
    public let status: DeploymentStatus?

    public init(metadata: ObjectMeta, spec: DeploymentSpec?, status: DeploymentStatus?) {
        self.metadata = metadata
        self.spec = spec
        self.status = status
    }

    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var desired: Int { spec?.replicas ?? 0 }
    public var ready: Int { status?.readyReplicas ?? 0 }
    public var updated: Int { status?.updatedReplicas ?? 0 }
    public var available: Int { status?.availableReplicas ?? 0 }
    public var strategy: String { spec?.strategy?.type ?? "-" }
    public var conditions: [DeploymentCondition] { status?.conditions ?? [] }
    public var isHealthy: Bool {
        guard desired > 0 else { return true }
        return ready == desired && available == desired && !hasBadCondition
    }
    public var hasBadCondition: Bool {
        conditions.contains { ($0.type == "Progressing" && $0.status == "False") ||
                              ($0.type == "Available" && $0.status == "False") ||
                              ($0.type == "ReplicaFailure" && $0.status == "True") }
    }
    public var unhealthyReason: String? {
        if !isHealthy {
            if let c = conditions.first(where: { $0.type == "ReplicaFailure" && $0.status == "True" }) {
                return c.reason ?? "ReplicaFailure"
            }
            if hasBadCondition { return "Progressing" }
            return "\(ready)/\(desired) ready"
        }
        return nil
    }
    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

public struct DeploymentSpec: Decodable, Hashable {
    public let replicas: Int?
    public let selector: LabelSelector?
    public let strategy: DeploymentStrategy?
}

public struct DeploymentStrategy: Decodable, Hashable { public let type: String? }

public struct DeploymentStatus: Decodable, Hashable {
    public let replicas: Int?
    public let readyReplicas: Int?
    public let updatedReplicas: Int?
    public let availableReplicas: Int?
    public let unavailableReplicas: Int?
    public let conditions: [DeploymentCondition]?
}

public struct DeploymentCondition: Decodable, Hashable {
    public let type: String
    public let status: String
    public let reason: String?
    public let message: String?
    public let lastUpdateTime: String?
}

public struct StatefulSetList: Decodable { public let items: [StatefulSet] }

public struct StatefulSet: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let spec: StatefulSetSpec?
    public let status: StatefulSetStatus?
    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var desired: Int { spec?.replicas ?? 0 }
    public var ready: Int { status?.readyReplicas ?? 0 }
    public var serviceName: String { spec?.serviceName ?? "-" }
    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

public struct StatefulSetSpec: Decodable, Hashable {
    public let replicas: Int?
    public let serviceName: String?
    public let selector: LabelSelector?
}

public struct StatefulSetStatus: Decodable, Hashable {
    public let replicas: Int?
    public let readyReplicas: Int?
    public let currentReplicas: Int?
    public let updatedReplicas: Int?
}

extension StatefulSet {
    public var isHealthy: Bool { desired == 0 || ready == desired }
    public var unhealthyReason: String? { isHealthy ? nil : "\(ready)/\(desired) ready" }
}

extension ReplicaSet {
    public var isHealthy: Bool { desired == 0 || ready == desired }
    public var unhealthyReason: String? { isHealthy ? nil : "\(ready)/\(desired) ready" }
}

extension KubeJob {
    public var isHealthy: Bool { failed == 0 }
    public var unhealthyReason: String? { failed > 0 ? "\(failed) failed" : nil }
}

public struct ReplicaSetList: Decodable { public let items: [ReplicaSet] }

public struct ReplicaSet: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let spec: ReplicaSetSpec?
    public let status: ReplicaSetStatus?

    public init(metadata: ObjectMeta, spec: ReplicaSetSpec?, status: ReplicaSetStatus?) {
        self.metadata = metadata
        self.spec = spec
        self.status = status
    }

    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var desired: Int { spec?.replicas ?? 0 }
    public var ready: Int { status?.readyReplicas ?? 0 }
    public var available: Int { status?.availableReplicas ?? 0 }
    public var ownerKind: String? { metadata.labels?["app.kubernetes.io/managed-by"] }
    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

public struct ReplicaSetSpec: Decodable, Hashable {
    public let replicas: Int?
    public let selector: LabelSelector?

    public init(replicas: Int?, selector: LabelSelector?) {
        self.replicas = replicas
        self.selector = selector
    }
}

public struct ReplicaSetStatus: Decodable, Hashable {
    public let replicas: Int?
    public let readyReplicas: Int?
    public let availableReplicas: Int?
}

public struct JobList: Decodable { public let items: [KubeJob] }

public struct KubeJob: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let spec: JobSpec?
    public let status: JobStatus?
    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var completions: Int { spec?.completions ?? 1 }
    public var parallelism: Int { spec?.parallelism ?? 1 }
    public var backoffLimit: Int { spec?.backoffLimit ?? 6 }
    public var active: Int { status?.active ?? 0 }
    public var succeeded: Int { status?.succeeded ?? 0 }
    public var failed: Int { status?.failed ?? 0 }
    public var phase: String {
        if failed > 0 { return "Failed" }
        if succeeded >= completions { return "Complete" }
        if active > 0 { return "Running" }
        return "Pending"
    }
    public var startTime: String? { status?.startTime }
    public var completionTime: String? { status?.completionTime }
    public var duration: String {
        guard let s = startTime else { return "-" }
        let f = ISO8601DateFormatter()
        guard let start = f.date(from: s) else { return "-" }
        let end: Date = (completionTime.flatMap { f.date(from: $0) }) ?? Date()
        let sec = Int(end.timeIntervalSince(start))
        if sec < 60 { return "\(sec)s" }
        if sec < 3600 { return "\(sec/60)m\(sec%60)s" }
        return "\(sec/3600)h\((sec%3600)/60)m"
    }
    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

public struct JobSpec: Decodable, Hashable {
    public let completions: Int?
    public let parallelism: Int?
    public let backoffLimit: Int?
    public let activeDeadlineSeconds: Int?
}

public struct JobStatus: Decodable, Hashable {
    public let active: Int?
    public let succeeded: Int?
    public let failed: Int?
    public let startTime: String?
    public let completionTime: String?
}

public struct CronJobList: Decodable { public let items: [CronJob] }

public struct CronJob: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let spec: CronJobSpec?
    public let status: CronJobStatus?
    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var schedule: String { spec?.schedule ?? "-" }
    public var suspend: Bool { spec?.suspend ?? false }
    public var activeCount: Int { status?.active?.count ?? 0 }
    public var lastScheduleTime: String? { status?.lastScheduleTime }
    public var lastSuccessfulTime: String? { status?.lastSuccessfulTime }
    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
    public var lastRunAge: String? {
        lastSuccessfulTime.map { Pod.formatAge(from: $0) }
    }
}

public struct CronJobSpec: Decodable, Hashable {
    public let schedule: String?
    public let suspend: Bool?
    public let concurrencyPolicy: String?
    public let successfulJobsHistoryLimit: Int?
    public let failedJobsHistoryLimit: Int?
}

public struct CronJobStatus: Decodable, Hashable {
    public let active: [ObjectReference]?
    public let lastScheduleTime: String?
    public let lastSuccessfulTime: String?
}

// MARK: - DaemonSet

public struct DaemonSetList: Decodable { public let items: [DaemonSet] }

public struct DaemonSet: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let spec: DaemonSetSpec?
    public let status: DaemonSetStatus?
    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var desired: Int { status?.desiredNumberScheduled ?? 0 }
    public var current: Int { status?.currentNumberScheduled ?? 0 }
    public var ready: Int { status?.numberReady ?? 0 }
    public var available: Int { status?.numberAvailable ?? 0 }
    public var isHealthy: Bool {
        desired == 0 || (ready == desired && available == desired)
    }
    public var unhealthyReason: String? {
        isHealthy ? nil : "\(ready)/\(desired) ready"
    }
    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

public struct DaemonSetSpec: Decodable, Hashable {
    public let selector: LabelSelector?
}

public struct DaemonSetStatus: Decodable, Hashable {
    public let desiredNumberScheduled: Int?
    public let currentNumberScheduled: Int?
    public let numberReady: Int?
    public let numberAvailable: Int?
    public let numberMisscheduled: Int?
}
