import Foundation
import SwiftUI

@MainActor
/// User-assigned display names for kube contexts. Contexts are frequently full
/// EKS ARNs, which are unreadable in a pill and identical for the first 40
/// characters. The kubeconfig is never rewritten — this is a display layer only,
/// so every kubectl call still uses the real context name.
final class ClusterNameStore: ObservableObject {
    @Published private var names: [String: String] = [:]
    private let defaultsKey = "kubeview.clusterNames"

    init() {
        names = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        #if DEBUG
        Self.selfCheck()
        #endif
    }

    /// What to show: the alias if there is one, otherwise the shortened context.
    func name(for context: String) -> String { names[context] ?? Self.shortened(context) }

    /// An EKS context is the whole cluster ARN, and everything before
    /// `cluster/` is identical for every cluster in the same account+region —
    /// so the tail is the only part that identifies it. Non-ARN contexts are
    /// left alone; a plain context is already the name.
    static func shortened(_ context: String) -> String {
        guard context.hasPrefix("arn:"), let slash = context.lastIndex(of: "/") else { return context }
        let tail = context[context.index(after: slash)...]
        return tail.isEmpty ? context : String(tail)
    }

    #if DEBUG
    static func selfCheck() {
        assert(shortened("arn:aws:eks:eu-central-1:314383174865:cluster/inno-prod-eks") == "inno-prod-eks")
        assert(shortened("stg-ap-eks") == "stg-ap-eks")
        // Not an ARN: leave anything with a slash untouched rather than guessing.
        assert(shortened("gke_project_zone_cluster/thing") == "gke_project_zone_cluster/thing")
        assert(shortened("arn:aws:eks:x:1:cluster/") == "arn:aws:eks:x:1:cluster/")
    }
    #endif

    /// The alias alone, for editors that need to distinguish "unset" from
    /// "set to the same string as the context".
    func alias(for context: String) -> String { names[context] ?? "" }

    func hasAlias(_ context: String) -> Bool { names[context] != nil }

    func set(_ name: String, for context: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { names.removeValue(forKey: context) }
        else { names[context] = trimmed }
        UserDefaults.standard.set(names, forKey: defaultsKey)
    }
}

final class StarStore: ObservableObject {
    @Published private var starred: Set<String> = []
    private let defaultsKey = "kubeview.starredNamespaces"

    init() {
        if let raw = UserDefaults.standard.array(forKey: defaultsKey) as? [String] {
            starred = Set(raw)
        }
    }

    func isStarred(_ namespace: String) -> Bool { starred.contains(namespace) }

    func toggle(_ namespace: String) {
        if starred.contains(namespace) { starred.remove(namespace) }
        else { starred.insert(namespace) }
        UserDefaults.standard.set(Array(starred), forKey: defaultsKey)
    }
}
