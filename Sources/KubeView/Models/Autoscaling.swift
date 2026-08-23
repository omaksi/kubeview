import Foundation

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
