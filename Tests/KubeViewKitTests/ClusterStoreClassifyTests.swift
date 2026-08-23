import XCTest
@testable import KubeViewKit

/// `ClusterStore.classify` has real branching logic - captured kubectl
/// error text, mapped to a typed `ConnectionFault` - and, unlike everything
/// else `ClusterStore.swift` owns, the existing `selfCheck()` never
/// exercises it at all. These are new coverage, not a self-check wrapper.
@MainActor
final class ClusterStoreClassifyTests: XCTestCase {
    func test_classify_unauthorized() {
        let (fault, _) = ClusterStore.classify("Unauthorized", context: "c")
        XCTAssertEqual(fault, .notLoggedIn)
    }

    func test_classify_noUsableCredentials() {
        let (fault, _) = ClusterStore.classify("Please enter Username: error: EOF", context: "c")
        XCTAssertEqual(fault, .notLoggedIn)
    }

    func test_classify_forbidden() {
        let (fault, _) = ClusterStore.classify("Error from server (Forbidden): pods is forbidden", context: "c")
        XCTAssertEqual(fault, .forbidden)
    }

    /// The order-matters case the file's own doc comment calls out: a TLS
    /// failure is reported *through* a connection error, so it must
    /// classify as `.tls`, not the generic `.unreachable`.
    func test_classify_tlsThroughConnectionError() {
        let (fault, _) = ClusterStore.classify(
            "Unable to connect to the server: x509: certificate signed by unknown authority",
            context: "c")
        XCTAssertEqual(fault, .tls)
    }

    func test_classify_unreachable_blackHoled() {
        let (fault, _) = ClusterStore.classify(
            "Unable to connect to the server: context deadline exceeded", context: "c")
        XCTAssertEqual(fault, .unreachable)
    }

    func test_classify_unreachable_refused() {
        let (fault, _) = ClusterStore.classify(
            "The connection to the server 1.2.3.4:6443 was refused", context: "c")
        XCTAssertEqual(fault, .unreachable)
    }

    func test_classify_unreachable_badDNS() {
        let (fault, _) = ClusterStore.classify(
            "dial tcp: lookup nope.example: no such host", context: "c")
        XCTAssertEqual(fault, .unreachable)
    }

    func test_classify_kubectlMissing() {
        let (fault, _) = ClusterStore.classify("kubectl not executable", context: "c")
        XCTAssertEqual(fault, .kubectlMissing)
    }

    func test_classify_fallsBackToOther() {
        let (fault, message) = ClusterStore.classify("something never seen before", context: "c")
        XCTAssertEqual(fault, .other)
        XCTAssertEqual(message, "something never seen before")
    }
}
