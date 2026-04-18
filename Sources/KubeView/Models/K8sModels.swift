import Foundation

struct KubeContext: Identifiable, Hashable {
    let name: String
    var id: String { name }
}

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

struct ObjectMeta: Decodable, Hashable {
    let name: String
    let namespace: String?
    let creationTimestamp: String?
    let labels: [String: String]?
    let annotations: [String: String]?
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

struct NodeList: Decodable {
    let items: [Node]
}

struct Node: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let status: NodeStatus?

    var id: String { metadata.name }
    var name: String { metadata.name }

    var readyCondition: String {
        guard let c = status?.conditions?.first(where: { $0.type == "Ready" }) else { return "Unknown" }
        return c.status == "True" ? "Ready" : "NotReady"
    }

    var kubeletVersion: String { status?.nodeInfo?.kubeletVersion ?? "-" }
    var os: String { status?.nodeInfo?.osImage ?? "-" }

    var cpuCapacityMillicores: Double {
        ResourceParser.cpuToMillicores(status?.capacity?["cpu"] ?? "0")
    }
    var memoryCapacityBytes: Double {
        ResourceParser.memoryToBytes(status?.capacity?["memory"] ?? "0")
    }
    var cpuAllocatableMillicores: Double {
        ResourceParser.cpuToMillicores(status?.allocatable?["cpu"] ?? "0")
    }
    var memoryAllocatableBytes: Double {
        ResourceParser.memoryToBytes(status?.allocatable?["memory"] ?? "0")
    }

    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct NodeStatus: Decodable, Hashable {
    let conditions: [NodeCondition]?
    let nodeInfo: NodeInfo?
    let capacity: [String: String]?
    let allocatable: [String: String]?
}

struct NodeCondition: Decodable, Hashable {
    let type: String
    let status: String
}

struct NodeInfo: Decodable, Hashable {
    let kubeletVersion: String
    let osImage: String
}

// MARK: - Namespaces

struct NamespaceList: Decodable { let items: [Namespace] }

struct Namespace: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let status: NamespaceStatus?
    var id: String { metadata.name }
    var name: String { metadata.name }
    var phase: String { status?.phase ?? "Active" }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
}

struct NamespaceStatus: Decodable, Hashable { let phase: String? }

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

// MARK: - ConfigMap (included for completeness; not yet surfaced)

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

struct LabelSelector: Decodable, Hashable {
    let matchLabels: [String: String]?
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

struct ObjectReference: Decodable, Hashable {
    let name: String?
    let namespace: String?
}

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

// MARK: - HorizontalPodAutoscaler (autoscaling/v2)

struct HPAList: Decodable { let items: [HPA] }

struct HPA: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let spec: HPASpec?
    let status: HPAStatus?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var targetKind: String { spec?.scaleTargetRef?.kind ?? "-" }
    var targetName: String { spec?.scaleTargetRef?.name ?? "-" }
    var minReplicas: Int { spec?.minReplicas ?? 1 }
    var maxReplicas: Int { spec?.maxReplicas ?? 0 }
    var currentReplicas: Int { status?.currentReplicas ?? 0 }
    var desiredReplicas: Int { status?.desiredReplicas ?? 0 }
    var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
    /// Compact metric summary for a card: e.g. `cpu: 45%/80%`.
    var metricSummary: String {
        let specs = spec?.metrics ?? []
        let stats = status?.currentMetrics ?? []
        return specs.enumerated().map { idx, m in
            let cur = idx < stats.count ? stats[idx] : nil
            return m.display(current: cur)
        }.joined(separator: ", ")
    }
}

struct HPASpec: Decodable, Hashable {
    let scaleTargetRef: ScaleTargetRef?
    let minReplicas: Int?
    let maxReplicas: Int?
    let metrics: [HPAMetricSpec]?
}

struct ScaleTargetRef: Decodable, Hashable {
    let kind: String?
    let name: String?
    let apiVersion: String?
}

struct HPAMetricSpec: Decodable, Hashable {
    let type: String
    let resource: HPAResourceSpec?
    func display(current: HPAMetricStatus?) -> String {
        guard let r = resource else { return type }
        let targetValue: String = {
            if let avg = r.target?.averageUtilization { return "\(avg)%" }
            if let v = r.target?.averageValue { return v }
            return "-"
        }()
        let currentValue: String = {
            guard let c = current?.resource else { return "?" }
            if let avg = c.current?.averageUtilization { return "\(avg)%" }
            if let v = c.current?.averageValue { return v }
            return "?"
        }()
        return "\(r.name): \(currentValue)/\(targetValue)"
    }
}

struct HPAResourceSpec: Decodable, Hashable {
    let name: String
    let target: HPAMetricTarget?
}

struct HPAMetricTarget: Decodable, Hashable {
    let type: String?
    let averageUtilization: Int?
    let averageValue: String?
    let value: String?
}

struct HPAStatus: Decodable, Hashable {
    let currentReplicas: Int?
    let desiredReplicas: Int?
    let currentMetrics: [HPAMetricStatus]?
    let conditions: [HPACondition]?
}

struct HPAMetricStatus: Decodable, Hashable {
    let type: String
    let resource: HPAResourceStatus?
}

struct HPAResourceStatus: Decodable, Hashable {
    let name: String
    let current: HPAMetricTarget?
}

struct HPACondition: Decodable, Hashable {
    let type: String
    let status: String
    let reason: String?
    let message: String?
}

struct EventList: Decodable { let items: [KubeEvent] }

struct KubeEvent: Decodable, Identifiable, Hashable {
    let metadata: ObjectMeta
    let type: String?
    let reason: String?
    let message: String?
    let count: Int?
    let firstTimestamp: String?
    let lastTimestamp: String?
    let eventTime: String?
    let involvedObject: InvolvedObject?
    var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    var when: String {
        let ts = lastTimestamp ?? firstTimestamp ?? eventTime ?? metadata.creationTimestamp ?? ""
        return ts.isEmpty ? "-" : Pod.formatAge(from: ts)
    }
}

struct InvolvedObject: Decodable, Hashable {
    let kind: String?
    let name: String?
    let namespace: String?
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

enum StringOrInt: Decodable, Hashable {
    case int(Int)
    case string(String)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        self = .string(try c.decode(String.self))
    }
    var display: String {
        switch self {
        case .int(let i): return String(i)
        case .string(let s): return s
        }
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

// MARK: - Metrics (metrics.k8s.io/v1beta1)

struct NodeMetricsList: Decodable { let items: [NodeMetrics] }

struct NodeMetrics: Decodable, Hashable {
    let metadata: ObjectMeta
    let usage: [String: String]
    var name: String { metadata.name }
    var cpu: String { usage["cpu"] ?? "0" }
    var memory: String { usage["memory"] ?? "0" }
}

struct PodMetricsList: Decodable { let items: [PodMetrics] }

struct PodMetrics: Decodable, Hashable {
    let metadata: ObjectMeta
    let containers: [ContainerMetrics]?
    var name: String { metadata.name }
    var namespace: String { metadata.namespace ?? "default" }
    var cpuMillicores: Double {
        (containers ?? []).reduce(0.0) { $0 + ResourceParser.cpuToMillicores($1.usage["cpu"] ?? "0") }
    }
    var memoryBytes: Double {
        (containers ?? []).reduce(0.0) { $0 + ResourceParser.memoryToBytes($1.usage["memory"] ?? "0") }
    }
}

struct ContainerMetrics: Decodable, Hashable {
    let name: String
    let usage: [String: String]
}

// MARK: - Resource parsing

enum ResourceParser {
    /// Convert CPU quantity ("500m", "1", "100u", "100n") to millicores.
    static func cpuToMillicores(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        if s.hasSuffix("n") { return (Double(s.dropLast()) ?? 0) / 1_000_000 }
        if s.hasSuffix("u") { return (Double(s.dropLast()) ?? 0) / 1_000 }
        if s.hasSuffix("m") { return Double(s.dropLast()) ?? 0 }
        return (Double(s) ?? 0) * 1000
    }

    /// Convert memory quantity ("128Mi", "1Gi", "500M", "1024") to bytes.
    static func memoryToBytes(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        let units: [(String, Double)] = [
            ("Ki", 1024), ("Mi", 1024*1024), ("Gi", pow(1024,3)), ("Ti", pow(1024,4)), ("Pi", pow(1024,5)),
            ("K", 1000), ("M", 1_000_000), ("G", 1_000_000_000), ("T", 1e12), ("P", 1e15)
        ]
        for (suffix, mult) in units where s.hasSuffix(suffix) {
            if let n = Double(s.dropLast(suffix.count)) { return n * mult }
        }
        return Double(s) ?? 0
    }

    static func formatMillicores(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.2f", m / 1000) }
        return "\(Int(m))m"
    }

    static func formatBytes(_ b: Double) -> String {
        let g = 1024.0 * 1024 * 1024
        let mi = 1024.0 * 1024
        if b >= g { return String(format: "%.1f Gi", b / g) }
        if b >= mi { return String(format: "%.0f Mi", b / mi) }
        return String(format: "%.0f", b)
    }
}
