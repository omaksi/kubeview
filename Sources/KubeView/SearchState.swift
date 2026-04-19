import Foundation
import SwiftUI

/// App-wide search box at the top of the window. On Overview the query
/// filters results across every resource type; on specific list views it acts
/// as the filter for that view's current list.
@MainActor
final class SearchState: ObservableObject {
    @Published var query: String = ""

    var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isActive: Bool { !trimmed.isEmpty }

    func matches(_ haystack: String?) -> Bool {
        guard let h = haystack, !trimmed.isEmpty else { return false }
        return h.lowercased().contains(trimmed.lowercased())
    }

    func matchesAny(_ strings: [String?]) -> Bool {
        guard !trimmed.isEmpty else { return true }
        let q = trimmed.lowercased()
        return strings.contains { ($0 ?? "").lowercased().contains(q) }
    }
}

/// Small helper used by list views:
///   filtered = items.apply(search, projecting: [\.name, \.namespace])
extension Collection {
    @MainActor
    func searchFiltered(_ search: SearchState, _ project: (Element) -> [String]) -> [Element] {
        guard search.isActive else { return Array(self) }
        let q = search.trimmed.lowercased()
        return filter { el in project(el).contains { $0.lowercased().contains(q) } }
    }
}
