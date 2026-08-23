import Foundation
import XCTest
import KubeModel
@testable import KubeViewKit

/// `ResourceGraph.selfCheck()` never passes non-empty `ingresses`/`hpas`
/// into `build(...)` - every call there uses `ingresses: []` and `hpas: []`.
/// That leaves the Ingress -> Service (`.routes`) and HPA -> target
/// (`.scales`) edge derivation - real branches in `build`, matched through
/// `byKindName` - with no coverage anywhere, self-check or otherwise. These
/// are new tests, not a self-check wrapper; they close that gap without
/// touching `ResourceGraph.swift` itself.
final class ResourceGraphEdgeCasesTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        // swiftlint:disable:next force_try - fixture literal, a decode failure here is a test bug
        try! JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func test_build_drawsScalesEdgeFromHPAToItsTarget() {
        let dep = decode(Deployment.self, """
        {"metadata":{"name":"web","namespace":"ns","uid":"d1"},"spec":null,"status":null}
        """)
        let hpa = decode(HPA.self, """
        {"metadata":{"name":"web-hpa","namespace":"ns","uid":"h1"},
         "spec":{"scaleTargetRef":{"kind":"Deployment","name":"web","apiVersion":"apps/v1"},
                 "minReplicas":1,"maxReplicas":5,"metrics":null},
         "status":null}
        """)
        let g = ResourceGraph.build(pods: [], services: [], ingresses: [], deployments: [dep],
                                    statefulSets: [], daemonSets: [], replicaSets: [], jobs: [],
                                    cronJobs: [], hpas: [hpa])
        XCTAssertTrue(g.edges.contains(GraphEdge(from: "h1", to: "d1", relation: .scales)))
    }

    func test_build_drawsRoutesEdgeFromIngressToItsService() {
        let svc = decode(Service.self, """
        {"metadata":{"name":"web","namespace":"ns","uid":"s1"},
         "spec":{"type":"ClusterIP","clusterIP":"10.0.0.1","ports":null,"selector":null,"externalIPs":null},
         "status":null}
        """)
        let ing = decode(Ingress.self, """
        {"metadata":{"name":"web-ing","namespace":"ns","uid":"i1"},
         "spec":{"ingressClassName":null,"tls":null,
                 "rules":[{"host":"example.com",
                           "http":{"paths":[{"path":"/","pathType":"Prefix",
                                             "backend":{"service":{"name":"web","port":{"number":80,"name":null}}}}]}}]},
         "status":null}
        """)
        let g = ResourceGraph.build(pods: [], services: [svc], ingresses: [ing], deployments: [],
                                    statefulSets: [], daemonSets: [], replicaSets: [], jobs: [],
                                    cronJobs: [], hpas: [])
        XCTAssertTrue(g.edges.contains(GraphEdge(from: "i1", to: "s1", relation: .routes)))
    }
}
