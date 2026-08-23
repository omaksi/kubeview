import Foundation

// MARK: - HorizontalPodAutoscaler (autoscaling/v2)

public struct HPAList: Decodable { public let items: [HPA] }

public struct HPA: Decodable, Identifiable, Hashable {
    public let metadata: ObjectMeta
    public let spec: HPASpec?
    public let status: HPAStatus?
    public var id: String { "\(metadata.namespace ?? "-")/\(metadata.name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var targetKind: String { spec?.scaleTargetRef?.kind ?? "-" }
    public var targetName: String { spec?.scaleTargetRef?.name ?? "-" }
    public var minReplicas: Int { spec?.minReplicas ?? 1 }
    public var maxReplicas: Int { spec?.maxReplicas ?? 0 }
    public var currentReplicas: Int { status?.currentReplicas ?? 0 }
    public var desiredReplicas: Int { status?.desiredReplicas ?? 0 }
    public var age: String {
        guard let ts = metadata.creationTimestamp else { return "-" }
        return Pod.formatAge(from: ts)
    }
    /// Compact metric summary for a card: e.g. `cpu: 45%/80%`.
    public var metricSummary: String {
        let specs = spec?.metrics ?? []
        let stats = status?.currentMetrics ?? []
        return specs.enumerated().map { idx, m in
            let cur = idx < stats.count ? stats[idx] : nil
            return m.display(current: cur)
        }.joined(separator: ", ")
    }
}

public struct HPASpec: Decodable, Hashable {
    public let scaleTargetRef: ScaleTargetRef?
    public let minReplicas: Int?
    public let maxReplicas: Int?
    public let metrics: [HPAMetricSpec]?
}

public struct ScaleTargetRef: Decodable, Hashable {
    public let kind: String?
    public let name: String?
    public let apiVersion: String?
}

public struct HPAMetricSpec: Decodable, Hashable {
    public let type: String
    public let resource: HPAResourceSpec?
    public func display(current: HPAMetricStatus?) -> String {
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

public struct HPAResourceSpec: Decodable, Hashable {
    public let name: String
    public let target: HPAMetricTarget?
}

public struct HPAMetricTarget: Decodable, Hashable {
    public let type: String?
    public let averageUtilization: Int?
    public let averageValue: String?
    public let value: String?
}

public struct HPAStatus: Decodable, Hashable {
    public let currentReplicas: Int?
    public let desiredReplicas: Int?
    public let currentMetrics: [HPAMetricStatus]?
    public let conditions: [HPACondition]?
}

public struct HPAMetricStatus: Decodable, Hashable {
    public let type: String
    public let resource: HPAResourceStatus?
}

public struct HPAResourceStatus: Decodable, Hashable {
    public let name: String
    public let current: HPAMetricTarget?
}

public struct HPACondition: Decodable, Hashable {
    public let type: String
    public let status: String
    public let reason: String?
    public let message: String?
}
