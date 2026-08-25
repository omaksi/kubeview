import XCTest
@testable import KubeViewKit

/// `WorkspaceTab.namespace` used to be `String?`, where nil meant "all
/// namespaces". That scope is gone, and the field is a plain `String` - but
/// workspaces persisted by an older build are still sitting in `UserDefaults`
/// with a literal `null` there.
///
/// Synthesized decoding throws on that, and because tabs are decoded as one
/// array, a single stale tab would take the whole workspace down and the user
/// would silently lose every tab on the first launch after upgrading. That is
/// what the hand-written `init(from:)` exists to prevent, so it is what these
/// pin.
@MainActor
final class WorkspaceTabDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> [WorkspaceTab] {
        try JSONDecoder().decode([WorkspaceTab].self, from: Data(json.utf8))
    }

    func test_decode_nullNamespace_fallsBackInsteadOfThrowing() throws {
        let tabs = try decode("""
        [{"id":"6B29FC40-CA47-1067-B31D-00DD010662DA","context":"stg","namespace":null,"view":"overview"}]
        """)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs[0].namespace, ClusterStore.fallbackNamespace)
        XCTAssertEqual(tabs[0].context, "stg")
    }

    func test_decode_missingNamespaceKey_fallsBack() throws {
        let tabs = try decode("""
        [{"id":"6B29FC40-CA47-1067-B31D-00DD010662DA","context":"stg","view":"overview"}]
        """)
        XCTAssertEqual(tabs[0].namespace, ClusterStore.fallbackNamespace)
    }

    /// The whole point: one stale tab must not cost the user the others.
    func test_decode_mixedOldAndNewTabs_keepsBoth() throws {
        let tabs = try decode("""
        [{"id":"6B29FC40-CA47-1067-B31D-00DD010662DA","context":"stg","namespace":null,"view":"overview"},
         {"id":"6B29FC40-CA47-1067-B31D-00DD010662DB","context":"prod","namespace":"kube-system","view":"pods"}]
        """)
        XCTAssertEqual(tabs.map(\.namespace), [ClusterStore.fallbackNamespace, "kube-system"])
    }

    /// A real namespace survives untouched - the fallback must not swallow it.
    func test_decode_realNamespace_isPreserved() throws {
        let tabs = try decode("""
        [{"id":"6B29FC40-CA47-1067-B31D-00DD010662DA","context":"stg","namespace":"observability","view":"overview"}]
        """)
        XCTAssertEqual(tabs[0].namespace, "observability")
    }

    func test_roundTrip_preservesNamespace() throws {
        let original = WorkspaceTab(context: "stg", namespace: "observability", view: .pods)
        let data = try JSONEncoder().encode([original])
        XCTAssertEqual(try JSONDecoder().decode([WorkspaceTab].self, from: data), [original])
    }

    /// There is no longer any way to express "all namespaces" through the tab.
    func test_defaultNamespace_isAConcreteNamespace() {
        XCTAssertEqual(WorkspaceTab(context: "stg").namespace, ClusterStore.fallbackNamespace)
        XCTAssertFalse(ClusterStore.fallbackNamespace.isEmpty)
    }
}
