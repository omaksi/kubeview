import XCTest
@testable import LgtmViewKit

/// Wraps the five hand-written `#if DEBUG` self-checks in this module that
/// today only run when `LgtmStore.init` happens to execute in a debug
/// build - i.e. only when a human opens the LGTM view. `assert` is live in
/// a debug build, so a violation traps and the test fails - this does not
/// reimplement their logic, it just gives them a caller in CI. Marked
/// `@MainActor` uniformly since `LgtmService`/`LgtmMetricsView`'s
/// self-checks call into `SeverityTag`/`LgtmMetricsView` itself (SwiftUI
/// `View`-conforming types); the other three are plain pure logic and would
/// run fine either way.
@MainActor
final class SelfCheckAdoptionTests: XCTestCase {
    func test_lgtmService_selfCheck() {
        LgtmService.selfCheck()
    }

    func test_lgtmTopology_selfCheck() {
        LgtmTopology.selfCheck()
    }

    func test_lgtmGraphLayout_selfCheck() {
        LgtmGraphLayout.selfCheck()
    }

    func test_lgtmClusterView_selfCheck() {
        LgtmClusterViewSelfCheck.run()
    }

    func test_lgtmMetricsView_selfCheck() {
        LgtmMetricsView.selfCheck()
    }
}
