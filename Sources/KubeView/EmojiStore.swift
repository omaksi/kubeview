import Foundation
import SwiftUI

enum ResourceKind: String, CaseIterable {
    case namespace, pod, node, service, ingress

    var accent: Color {
        switch self {
        case .namespace: return .blue
        case .pod:       return .cyan
        case .node:      return .teal
        case .service:   return .indigo
        case .ingress:   return .purple
        }
    }

    var icon: String {
        switch self {
        case .namespace: return "square.stack.3d.up"
        case .pod:       return "shippingbox"
        case .node:      return "server.rack"
        case .service:   return "bolt.horizontal.circle"
        case .ingress:   return "network"
        }
    }

    var title: String {
        switch self {
        case .namespace: return "Namespace"
        case .pod:       return "Pod"
        case .node:      return "Node"
        case .service:   return "Service"
        case .ingress:   return "Ingress"
        }
    }
}

struct ResourceRef: Hashable {
    let kind: ResourceKind
    /// Namespace-scoped: "<ns>/<name>". Cluster-scoped: "<name>".
    let key: String
    var storageKey: String { "\(kind.rawValue):\(key)" }

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

/// Deterministic tint for a namespace name, so the same namespace is always the
/// same color across the UI. Subtle — meant for backgrounds, not text.
enum NamespacePalette {
    static let palette: [Color] = [
        .blue, .purple, .pink, .orange, .green, .teal, .indigo, .cyan, .mint, .yellow, .red
    ]
    static func color(for name: String) -> Color {
        var hasher = Hasher()
        hasher.combine(name)
        let h = abs(hasher.finalize())
        return palette[h % palette.count]
    }
}
