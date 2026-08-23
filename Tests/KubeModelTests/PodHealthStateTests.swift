import Foundation
import XCTest
@testable import KubeModel

/// `Pod.healthState` and its `isFailing`/`failureReason` derivatives are pure
/// classification over already-decoded JSON - the whole point of the
/// ImagePullBackOff/CrashLoopBackOff detection that `phase` alone misses.
final class PodHealthStateTests: XCTestCase {
    private func decodePod(_ json: String) -> Pod {
        // swiftlint:disable:next force_try - fixture literal, a decode failure here is a test bug
        try! JSONDecoder().decode(Pod.self, from: Data(json.utf8))
    }

    func test_succeededPhase_isOK() {
        let pod = decodePod("""
        {"metadata":{"name":"p","namespace":"ns"},"status":{"phase":"Succeeded"},"spec":null}
        """)
        XCTAssertEqual(pod.healthState, .ok)
        XCTAssertFalse(pod.isFailing)
    }

    func test_failedPhase_isFailingWithReason() {
        let pod = decodePod("""
        {"metadata":{"name":"p","namespace":"ns"},"status":{"phase":"Failed","reason":"Evicted"},"spec":null}
        """)
        XCTAssertEqual(pod.healthState, .failing(reason: "Evicted"))
        XCTAssertTrue(pod.isFailing)
        XCTAssertEqual(pod.failureReason, "Evicted")
    }

    func test_runningWithCrashLoopBackOff_isFailingEvenThoughPhaseIsRunning() {
        let pod = decodePod("""
        {"metadata":{"name":"p","namespace":"ns"},
         "status":{"phase":"Running","containerStatuses":[{"name":"c","ready":false,"restartCount":3,
                    "state":{"waiting":{"reason":"CrashLoopBackOff"}}}]},
         "spec":{"containers":[{"name":"c","image":"x"}]}}
        """)
        XCTAssertEqual(pod.healthState, .failing(reason: "CrashLoopBackOff"))
        XCTAssertTrue(pod.isFailing)
    }

    func test_runningAllContainersReady_isOK() {
        let pod = decodePod("""
        {"metadata":{"name":"p","namespace":"ns"},
         "status":{"phase":"Running","containerStatuses":[{"name":"c","ready":true,"restartCount":0}]},
         "spec":{"containers":[{"name":"c","image":"x"}]}}
        """)
        XCTAssertEqual(pod.healthState, .ok)
    }

    func test_runningNotAllContainersReady_isPending() {
        let pod = decodePod("""
        {"metadata":{"name":"p","namespace":"ns"},
         "status":{"phase":"Running","containerStatuses":[{"name":"c","ready":false,"restartCount":0}]},
         "spec":{"containers":[{"name":"c","image":"x"}]}}
        """)
        XCTAssertEqual(pod.healthState, .pending)
        XCTAssertFalse(pod.isFailing)
    }

    func test_pendingPhase_isPending() {
        let pod = decodePod("""
        {"metadata":{"name":"p","namespace":"ns"},"status":{"phase":"Pending"},"spec":null}
        """)
        XCTAssertEqual(pod.healthState, .pending)
    }

    func test_isLinkerdMeshed_detectsSidecarByName() {
        let meshed = decodePod("""
        {"metadata":{"name":"p","namespace":"ns"},"status":null,
         "spec":{"containers":[{"name":"app","image":"x"},{"name":"linkerd-proxy","image":"y"}]}}
        """)
        let unmeshed = decodePod("""
        {"metadata":{"name":"p","namespace":"ns"},"status":null,
         "spec":{"containers":[{"name":"app","image":"x"}]}}
        """)
        XCTAssertTrue(meshed.isLinkerdMeshed)
        XCTAssertFalse(unmeshed.isLinkerdMeshed)
    }

    // MARK: - formatAge

    func test_formatAge_malformedTimestampReturnsDash() {
        XCTAssertEqual(Pod.formatAge(from: "not-a-date"), "-")
    }

    func test_formatAge_bucketsBySeconds_Minutes_Hours_Days() {
        let f = ISO8601DateFormatter()
        func iso(_ secondsAgo: TimeInterval) -> String { f.string(from: Date().addingTimeInterval(-secondsAgo)) }

        XCTAssertTrue(Pod.formatAge(from: iso(30)).hasSuffix("s"))
        XCTAssertTrue(Pod.formatAge(from: iso(5 * 60)).hasSuffix("m"))
        XCTAssertTrue(Pod.formatAge(from: iso(5 * 3600)).hasSuffix("h"))
        XCTAssertTrue(Pod.formatAge(from: iso(5 * 86400)).hasSuffix("d"))
    }
}
