import Foundation

// MARK: - Workloads

struct DeploymentList: Decodable { let items: [Deployment] }

struct Deployment: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let spec: DeploymentSpec?
    let status: DeploymentStatus?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var desired: Int { spec?.replicas ?? 0 }
    var ready: Int { status?.readyReplicas ?? 0 }
    var updated: Int { status?.updatedReplicas ?? 0 }
    var available: Int { status?.availableReplicas ?? 0 }
    var strategy: String { spec?.strategy?.type ?? "-" }
    var conditions: [DeploymentCondition] { status?.conditions ?? [] }
    var isHealthy: Bool {
        guard desired > 0 else { return true }
        return ready == desired && available == desired && !hasBadCondition
    }
    var hasBadCondition: Bool {
        conditions.contains { ($0.type == "Progressing" && $0.status == "False") ||
                              ($0.type == "Available" && $0.status == "False") ||
                              ($0.type == "ReplicaFailure" && $0.status == "True") }
    }
    var unhealthyReason: String? {
        if !isHealthy {
            if let c = conditions.first(where: { $0.type == "ReplicaFailure" && $0.status == "True" }) {
                return c.reason ?? "ReplicaFailure"
            }
            if hasBadCondition { return "Progressing" }
            return "\(ready)/\(desired) ready"
        }
        return nil
    }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct DeploymentSpec: Decodable, Hashable {
    let replicas: Int?
    let selector: LabelSelector?
    let strategy: DeploymentStrategy?
}

struct DeploymentStrategy: Decodable, Hashable { let type: String? }

struct DeploymentStatus: Decodable, Hashable {
    let replicas: Int?
    let readyReplicas: Int?
    let updatedReplicas: Int?
    let availableReplicas: Int?
    let unavailableReplicas: Int?
    let conditions: [DeploymentCondition]?
}

struct DeploymentCondition: Decodable, Hashable {
    let type: String
    let status: String
    let reason: String?
    let message: String?
    let lastUpdateTime: String?
}

struct StatefulSetList: Decodable { let items: [StatefulSet] }

struct StatefulSet: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let spec: StatefulSetSpec?
    let status: StatefulSetStatus?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var desired: Int { spec?.replicas ?? 0 }
    var ready: Int { status?.readyReplicas ?? 0 }
    var serviceName: String { spec?.serviceName ?? "-" }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct StatefulSetSpec: Decodable, Hashable {
    let replicas: Int?
    let serviceName: String?
    let selector: LabelSelector?
}

struct StatefulSetStatus: Decodable, Hashable {
    let replicas: Int?
    let readyReplicas: Int?
    let currentReplicas: Int?
    let updatedReplicas: Int?
}

extension StatefulSet {
    var isHealthy: Bool { desired == 0 || ready == desired }
    var unhealthyReason: String? { isHealthy ? nil : "\(ready)/\(desired) ready" }
}

extension ReplicaSet {
    var isHealthy: Bool { desired == 0 || ready == desired }
    var unhealthyReason: String? { isHealthy ? nil : "\(ready)/\(desired) ready" }
}

extension KubeJob {
    var isHealthy: Bool { failed == 0 }
    var unhealthyReason: String? { failed > 0 ? "\(failed) failed" : nil }
}

struct ReplicaSetList: Decodable { let items: [ReplicaSet] }

struct ReplicaSet: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let spec: ReplicaSetSpec?
    let status: ReplicaSetStatus?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var desired: Int { spec?.replicas ?? 0 }
    var ready: Int { status?.readyReplicas ?? 0 }
    var available: Int { status?.availableReplicas ?? 0 }
    var ownerKind: String? { metadata.labels?["app.kubernetes.io/managed-by"] }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct ReplicaSetSpec: Decodable, Hashable {
    let replicas: Int?
    let selector: LabelSelector?
}

struct ReplicaSetStatus: Decodable, Hashable {
    let replicas: Int?
    let readyReplicas: Int?
    let availableReplicas: Int?
}

struct JobList: Decodable { let items: [KubeJob] }

struct KubeJob: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let spec: JobSpec?
    let status: JobStatus?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var completions: Int { spec?.completions ?? 1 }
    var parallelism: Int { spec?.parallelism ?? 1 }
    var backoffLimit: Int { spec?.backoffLimit ?? 6 }
    var active: Int { status?.active ?? 0 }
    var succeeded: Int { status?.succeeded ?? 0 }
    var failed: Int { status?.failed ?? 0 }
    var phase: String {
        if failed > 0 { return "Failed" }
        if succeeded >= completions { return "Complete" }
        if active > 0 { return "Running" }
        return "Pending"
    }
    var startTime: String? { status?.startTime }
    var completionTime: String? { status?.completionTime }
    var duration: String {
        guard let s = startTime else { return "-" }
        let f = ISO8601DateFormatter()
        guard let start = f.date(from: s) else { return "-" }
        let end: Date = (completionTime.flatMap { f.date(from: $0) }) ?? Date()
        let sec = Int(end.timeIntervalSince(start))
        if sec < 60 { return "\(sec)s" }
        if sec < 3600 { return "\(sec/60)m\(sec%60)s" }
        return "\(sec/3600)h\((sec%3600)/60)m"
    }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct JobSpec: Decodable, Hashable {
    let completions: Int?
    let parallelism: Int?
    let backoffLimit: Int?
    let activeDeadlineSeconds: Int?
}

struct JobStatus: Decodable, Hashable {
    let active: Int?
    let succeeded: Int?
    let failed: Int?
    let startTime: String?
    let completionTime: String?
}

struct CronJobList: Decodable { let items: [CronJob] }

struct CronJob: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let spec: CronJobSpec?
    let status: CronJobStatus?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var schedule: String { spec?.schedule ?? "-" }
    var suspend: Bool { spec?.suspend ?? false }
    var activeCount: Int { status?.active?.count ?? 0 }
    var lastScheduleTime: String? { status?.lastScheduleTime }
    var lastSuccessfulTime: String? { status?.lastSuccessfulTime }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
    var lastRunAge: String? {
        lastSuccessfulTime.map { Pod.formatAge(from: $0) }
    }
}

struct CronJobSpec: Decodable, Hashable {
    let schedule: String?
    let suspend: Bool?
    let concurrencyPolicy: String?
    let successfulJobsHistoryLimit: Int?
    let failedJobsHistoryLimit: Int?
}

struct CronJobStatus: Decodable, Hashable {
    let active: [ObjectReference]?
    let lastScheduleTime: String?
    let lastSuccessfulTime: String?
}

// MARK: - DaemonSet

struct DaemonSetList: Decodable { let items: [DaemonSet] }

struct DaemonSet: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let spec: DaemonSetSpec?
    let status: DaemonSetStatus?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var desired: Int { status?.desiredNumberScheduled ?? 0 }
    var current: Int { status?.currentNumberScheduled ?? 0 }
    var ready: Int { status?.numberReady ?? 0 }
    var available: Int { status?.numberAvailable ?? 0 }
    var isHealthy: Bool {
        desired == 0 || (ready == desired && available == desired)
    }
    var unhealthyReason: String? {
        isHealthy ? nil : "\(ready)/\(desired) ready"
    }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct DaemonSetSpec: Decodable, Hashable {
    let selector: LabelSelector?
}

struct DaemonSetStatus: Decodable, Hashable {
    let desiredNumberScheduled: Int?
    let currentNumberScheduled: Int?
    let numberReady: Int?
    let numberAvailable: Int?
    let numberMisscheduled: Int?
}
