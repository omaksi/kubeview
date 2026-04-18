import Foundation
import SwiftUI

enum ResourceKind: String, CaseIterable {
    case namespace, pod, node, service, ingress
    case secret, pvc, storageClass, networkPolicy, serviceAccount
    case statefulSet, replicaSet, job, cronJob, daemonSet
    case configMap, hpa, event
    case irsa, linkerd

    var accent: Color {
        switch self {
        case .namespace:      return .blue
        case .pod:            return .cyan
        case .node:            return .teal
        case .service:         return .indigo
        case .ingress:         return .purple
        case .secret:          return .red
        case .pvc:             return .brown
        case .storageClass:    return .brown
        case .networkPolicy:   return .purple
        case .serviceAccount:  return .orange
        case .statefulSet:     return .mint
        case .replicaSet:      return .cyan
        case .job:             return .yellow
        case .cronJob:         return .yellow
        case .daemonSet:       return .mint
        case .configMap:       return .gray
        case .hpa:             return .green
        case .event:           return .teal
        case .irsa:            return .orange
        case .linkerd:         return .pink
        }
    }

    var icon: String {
        switch self {
        case .namespace:       return "square.stack.3d.up"
        case .pod:             return "shippingbox"
        case .node:            return "server.rack"
        case .service:         return "bolt.horizontal.circle"
        case .ingress:         return "network"
        case .secret:          return "key.fill"
        case .pvc:             return "externaldrive"
        case .storageClass:    return "internaldrive"
        case .networkPolicy:   return "shield.lefthalf.filled"
        case .serviceAccount:  return "person.badge.key"
        case .statefulSet:     return "cylinder.split.1x2"
        case .replicaSet:      return "rectangle.stack"
        case .job:             return "hammer"
        case .cronJob:         return "clock.arrow.circlepath"
        case .daemonSet:       return "square.stack.3d.down.right"
        case .configMap:       return "doc.plaintext"
        case .hpa:             return "arrow.up.and.down.and.arrow.left.and.right"
        case .event:           return "bell"
        case .irsa:            return "person.badge.shield.checkmark"
        case .linkerd:         return "link"
        }
    }

    /// kubectl resource name usable with `kubectl describe <resource>`.
    /// Returns nil for kinds that aren't directly describable (IRSA is a
    /// filtered SA view; Linkerd/Event are aggregates).
    var kubectlResource: String? {
        switch self {
        case .namespace:       return "namespace"
        case .pod:             return "pod"
        case .node:            return "node"
        case .service:         return "service"
        case .ingress:         return "ingress"
        case .secret:          return "secret"
        case .pvc:             return "pvc"
        case .storageClass:    return "storageclass"
        case .networkPolicy:   return "networkpolicy"
        case .serviceAccount:  return "serviceaccount"
        case .statefulSet:     return "statefulset"
        case .replicaSet:      return "replicaset"
        case .job:             return "job"
        case .cronJob:         return "cronjob"
        case .daemonSet:       return "daemonset"
        case .configMap:       return "configmap"
        case .hpa:             return "hpa"
        case .irsa:            return "serviceaccount"
        case .linkerd, .event: return nil
        }
    }

    var title: String {
        switch self {
        case .namespace:       return "Namespace"
        case .pod:             return "Pod"
        case .node:            return "Node"
        case .service:         return "Service"
        case .ingress:         return "Ingress"
        case .secret:          return "Secret"
        case .pvc:             return "PVC"
        case .storageClass:    return "StorageClass"
        case .networkPolicy:   return "NetworkPolicy"
        case .serviceAccount:  return "ServiceAccount"
        case .statefulSet:     return "StatefulSet"
        case .replicaSet:      return "ReplicaSet"
        case .job:             return "Job"
        case .cronJob:         return "CronJob"
        case .daemonSet:       return "DaemonSet"
        case .configMap:       return "ConfigMap"
        case .hpa:             return "HPA"
        case .event:           return "Event"
        case .irsa:            return "IRSA"
        case .linkerd:         return "Linkerd"
        }
    }
}

struct ResourceRef: Hashable {
    let kind: ResourceKind
    /// Namespace-scoped: "<ns>/<name>". Cluster-scoped: "<name>".
    let key: String
    var storageKey: String { "\(kind.rawValue):\(key)" }

    /// The resource's namespace, or nil for cluster-scoped kinds.
    var namespace: String? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? parts[0] : nil
    }

    /// The resource's name (without namespace prefix).
    var resourceName: String {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? parts[1] : key
    }

    static func namespace(_ name: String) -> ResourceRef { .init(kind: .namespace, key: name) }
    static func pod(_ ns: String, _ name: String) -> ResourceRef { .init(kind: .pod, key: "\(ns)/\(name)") }
    static func node(_ name: String) -> ResourceRef { .init(kind: .node, key: name) }
    static func service(_ ns: String, _ name: String) -> ResourceRef { .init(kind: .service, key: "\(ns)/\(name)") }
    static func ingress(_ ns: String, _ name: String) -> ResourceRef { .init(kind: .ingress, key: "\(ns)/\(name)") }
}

@MainActor
final class EmojiStore: ObservableObject {
    @Published private var map: [String: String] = [:]
    private let defaultsKey = "kubeview.emojiMap"

    init() { load() }

    func emoji(for ref: ResourceRef) -> String? { map[ref.storageKey] }

    func set(_ emoji: String?, for ref: ResourceRef) {
        let trimmed = emoji?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = trimmed, !e.isEmpty {
            map[ref.storageKey] = e
        } else {
            map.removeValue(forKey: ref.storageKey)
        }
        save()
    }

    private func load() {
        if let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] {
            map = raw
        }
    }

    private func save() {
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }
}

