import Foundation
import XCTest
@testable import KubeModel

/// `isHealthy`/`unhealthyReason` are pure ready-vs-desired classification
/// over already-decoded JSON - the same shape repeated across workload
/// kinds: `Deployment` inline (the richest - it also weighs conditions), the
/// rest via the `extension X { var isHealthy }` blocks in Workloads.swift.
final class WorkloadHealthTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        // swiftlint:disable:next force_try - fixture literal, a decode failure here is a test bug
        try! JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Deployment

    func test_deployment_scaledToZero_isHealthyRegardless() {
        let d = decode(Deployment.self, """
        {"metadata":{"name":"d","namespace":"ns"},"spec":{"replicas":0},"status":{"readyReplicas":0,"availableReplicas":0}}
        """)
        XCTAssertTrue(d.isHealthy)
        XCTAssertNil(d.unhealthyReason)
    }

    func test_deployment_readyMatchesDesired_isHealthy() {
        let d = decode(Deployment.self, """
        {"metadata":{"name":"d","namespace":"ns"},"spec":{"replicas":3},"status":{"readyReplicas":3,"availableReplicas":3}}
        """)
        XCTAssertTrue(d.isHealthy)
    }

    func test_deployment_underReplicated_reportsReadyOverDesired() {
        let d = decode(Deployment.self, """
        {"metadata":{"name":"d","namespace":"ns"},"spec":{"replicas":3},"status":{"readyReplicas":1,"availableReplicas":1}}
        """)
        XCTAssertFalse(d.isHealthy)
        XCTAssertEqual(d.unhealthyReason, "1/3 ready")
    }

    func test_deployment_replicaFailureCondition_isUnhealthyEvenWhenFullyReady() {
        let d = decode(Deployment.self, """
        {"metadata":{"name":"d","namespace":"ns"},"spec":{"replicas":3},
         "status":{"readyReplicas":3,"availableReplicas":3,
                   "conditions":[{"type":"ReplicaFailure","status":"True","reason":"FailedCreate"}]}}
        """)
        XCTAssertFalse(d.isHealthy, "a bad condition must outrank ready == desired")
        XCTAssertEqual(d.unhealthyReason, "FailedCreate")
    }

    // MARK: - StatefulSet

    func test_statefulSet_scaledToZero_isHealthy() {
        let s = decode(StatefulSet.self, """
        {"metadata":{"name":"s","namespace":"ns"},"spec":{"replicas":0},"status":{"readyReplicas":0}}
        """)
        XCTAssertTrue(s.isHealthy)
    }

    func test_statefulSet_underReplicated_reportsReadyOverDesired() {
        let s = decode(StatefulSet.self, """
        {"metadata":{"name":"s","namespace":"ns"},"spec":{"replicas":2},"status":{"readyReplicas":1}}
        """)
        XCTAssertFalse(s.isHealthy)
        XCTAssertEqual(s.unhealthyReason, "1/2 ready")
    }

    // MARK: - ReplicaSet

    func test_replicaSet_readyMatchesDesired_isHealthy() {
        let r = decode(ReplicaSet.self, """
        {"metadata":{"name":"r","namespace":"ns"},"spec":{"replicas":3},"status":{"readyReplicas":3}}
        """)
        XCTAssertTrue(r.isHealthy)
    }

    func test_replicaSet_underReplicated_reportsReadyOverDesired() {
        let r = decode(ReplicaSet.self, """
        {"metadata":{"name":"r","namespace":"ns"},"spec":{"replicas":3},"status":{"readyReplicas":2}}
        """)
        XCTAssertFalse(r.isHealthy)
        XCTAssertEqual(r.unhealthyReason, "2/3 ready")
    }

    // MARK: - KubeJob

    func test_kubeJob_noFailures_isHealthy() {
        let j = decode(KubeJob.self, """
        {"metadata":{"name":"j","namespace":"ns"},"spec":null,"status":{"failed":0}}
        """)
        XCTAssertTrue(j.isHealthy)
        XCTAssertNil(j.unhealthyReason)
    }

    func test_kubeJob_failures_reportsCount() {
        let j = decode(KubeJob.self, """
        {"metadata":{"name":"j","namespace":"ns"},"spec":null,"status":{"failed":2}}
        """)
        XCTAssertFalse(j.isHealthy)
        XCTAssertEqual(j.unhealthyReason, "2 failed")
    }

    // MARK: - DaemonSet

    func test_daemonSet_readyAndAvailableMatchDesired_isHealthy() {
        let ds = decode(DaemonSet.self, """
        {"metadata":{"name":"ds","namespace":"ns"},"spec":null,
         "status":{"desiredNumberScheduled":5,"numberReady":5,"numberAvailable":5}}
        """)
        XCTAssertTrue(ds.isHealthy)
    }

    func test_daemonSet_underReady_reportsReadyOverDesired() {
        let ds = decode(DaemonSet.self, """
        {"metadata":{"name":"ds","namespace":"ns"},"spec":null,
         "status":{"desiredNumberScheduled":5,"numberReady":3,"numberAvailable":3}}
        """)
        XCTAssertFalse(ds.isHealthy)
        XCTAssertEqual(ds.unhealthyReason, "3/5 ready")
    }
}
