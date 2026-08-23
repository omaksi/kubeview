import XCTest
@testable import KubeViewKit

/// Wraps the five hand-written `#if DEBUG` self-checks in this module that
/// today only run when a human launches a debug build and opens the view
/// that happens to construct the owning store. `assert` is live in a debug
/// build, so a violation traps and the test fails - this does not
/// reimplement their logic (that would create a second copy to drift from
/// the first), it just gives them a caller in CI.
final class SelfCheckAdoptionTests: XCTestCase {
    func test_resourceGraph_selfCheck() {
        ResourceGraph.selfCheck()
    }

    @MainActor
    func test_clusterStore_selfCheck() {
        ClusterStore.selfCheck()
    }

    func test_awsConfigParser_selfCheck() {
        AwsConfigParser.selfCheck()
    }

    @MainActor
    func test_clusterNameStore_selfCheck() {
        ClusterNameStore.selfCheck()
    }

    @MainActor
    func test_tabStore_selfCheck() {
        TabStore.selfCheck()
    }
}
