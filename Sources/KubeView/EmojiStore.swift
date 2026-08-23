import Foundation
import SwiftUI

/// `ResourceKind`'s cases, `kubectlResource` and `title` live in
/// `Models/ResourceKind.swift`, Foundation-only - a future non-GUI module
/// (CLI, background agent) has to depend on the model layer without linking
/// SwiftUI. `accent` and `icon` are presentation and stay here regardless of
/// `icon` merely being a `String` under the hood.
extension ResourceKind {
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
        case .deployment:      return .indigo
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
        case .awsProfile:      return .orange
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
        case .deployment:      return "square.grid.2x2"
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
        case .awsProfile:      return "key.horizontal"
        }
    }
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

