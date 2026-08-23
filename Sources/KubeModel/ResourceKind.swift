import Foundation

public enum ResourceKind: String, CaseIterable {
    case namespace, pod, node, service, ingress
    case secret, pvc, storageClass, networkPolicy, serviceAccount
    case deployment, statefulSet, replicaSet, job, cronJob, daemonSet
    case configMap, hpa, event
    case irsa, linkerd, awsProfile

    /// kubectl resource name usable with `kubectl describe <resource>`.
    /// Returns nil for kinds that aren't directly describable (IRSA is a
    /// filtered SA view; Linkerd/Event are aggregates).
    public var kubectlResource: String? {
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
        case .deployment:      return "deployment"
        case .statefulSet:     return "statefulset"
        case .replicaSet:      return "replicaset"
        case .job:             return "job"
        case .cronJob:         return "cronjob"
        case .daemonSet:       return "daemonset"
        case .configMap:       return "configmap"
        case .hpa:             return "hpa"
        case .irsa:            return "serviceaccount"
        case .linkerd, .event, .awsProfile: return nil
        }
    }

    public var title: String {
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
        case .deployment:      return "Deployment"
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
        case .awsProfile:      return "AWS Profile"
        }
    }
}
