import Foundation

// MARK: - Wire format
//
// Mirrors `kubectl-lgtm --json`. That tool owns the analysis — it queries the
// stack's own Mimir/Prometheus over PromQL and runs a rule catalogue over the
// result — and this app owns the presentation. Reimplementing the rules in
// Swift would mean a second PromQL client and a second copy of the thresholds.

struct LgtmReport: Decodable {
    let version: String
    let generatedAt: Date
    let context: String
    let scope: String
    let source: String
    /// A caveat about the metrics store. Today: a Mimir holding several
    /// clusters, which means every number here aggregates across all of them
    /// and a max from a busier cluster reads as this one's.
    let warning: String?
    /// False when the report was produced without querying the metrics store —
    /// either `--no-metrics`, or the store was unreachable. Optional so an older
    /// binary that predates the field still decodes; absent means "assume yes".
    let metricsAvailable: Bool?
    let windowSecs: Double
    let components: [LgtmComponent]
}

struct LgtmComponent: Decodable, Identifiable, Hashable {
    let name: String
    let namespace: String
    let kind: String
    let product: String
    let role: String
    let zone: String
    let title: String
    /// Regex matching this workload's pods. The join key between a component
    /// and the live pods KubeView already holds. Optional for the same reason
    /// as `metricsAvailable`.
    let podPattern: String?

    let replicas: Int
    let readyReplicas: Int
    let stateful: Bool

    let cpuRequestMillis: Int
    let cpuLimitMillis: Int
    let memRequestBytes: Int
    let memLimitBytes: Int

    let usage: LgtmUsage
    let note: String
    /// "" when the component has no findings.
    let severity: String
    let findings: [LgtmFinding]

    var id: String { "\(namespace)/\(name)" }
    var healthy: Bool { replicas == 0 || readyReplicas == replicas }
}

/// One replica's own measurements. The scalars on `LgtmUsage` are the max
/// across these; a view showing what the cluster is actually doing should read
/// these instead, because collapsing replicas hides the case where one carries
/// the load and the rest idle.
struct LgtmPodUsage: Decodable, Hashable, Identifiable {
    let name: String
    let memP99Bytes: Double
    let memMaxBytes: Double
    let cpuP99Millis: Double
    let throttleRatio: Double
    let oomContainers: Double
    let restarts: Double

    var id: String { name }
}

struct LgtmUsage: Decodable, Hashable {
    let memP99Bytes: Double
    let memMaxBytes: Double
    let cpuP99Millis: Double
    let throttleRatio: Double
    let oomContainers: Double
    let restarts: Double
    let coverageSecs: Double
    let series: [Double]
    /// Optional so a report from an analyser predating per-pod output still
    /// decodes. Absent and empty mean the same thing here: nothing to show.
    // `var` with a default on purpose: a `let` with a default is dropped from
    // the synthesized memberwise init entirely, which would leave existing
    // construction sites unable to pass pods at all. This way they compile
    // unchanged and can opt in.
    var pods: [LgtmPodUsage]? = nil
}

extension LgtmUsage {
    var replicas: [LgtmPodUsage] { pods ?? [] }

    /// Busiest and quietest replica by memory, for the imbalance signal. nil
    /// when there is nothing to compare - one replica, or no measurements.
    var memorySpread: (low: LgtmPodUsage, high: LgtmPodUsage)? {
        let withData = replicas.filter { $0.memP99Bytes > 0 }
        guard withData.count > 1,
              let low = withData.min(by: { $0.memP99Bytes < $1.memP99Bytes }),
              let high = withData.max(by: { $0.memP99Bytes < $1.memP99Bytes }) else { return nil }
        return (low, high)
    }
}

struct LgtmFinding: Decodable, Hashable, Identifiable {
    let rule: String
    let severity: String
    let title: String
    let current: String
    let suggested: String
    let rationale: String
    let confidence: String
    let windowSecs: Double
    let snippet: String
    let grafanaUrl: String?
    let evidence: [LgtmEvidence]

    var id: String { rule + title }
}

struct LgtmEvidence: Decodable, Hashable {
    let expr: String
    let value: String
}

// MARK: - Service

enum LgtmService {
    /// The bundled copy wins so a released `.app` works with nothing installed;
    /// a Homebrew install is the fallback for running from `swift run`.
    static var binary: String? {
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "kubectl-lgtm")?.path {
            candidates.append(bundled)
        }
        candidates += [
            "/opt/homebrew/bin/kubectl-lgtm",
            "/usr/local/bin/kubectl-lgtm",
            "\(NSHomeDirectory())/go/bin/kubectl-lgtm"
        ]
        return Subprocess.locate(candidates)
    }

    /// Generous, and deliberately so: a full pass opens a port-forward into the
    /// cluster and issues six PromQL queries per component over the lookback
    /// window. A 30-component stack takes ~20s against a healthy Mimir and
    /// several times that against a struggling one - which is exactly when
    /// someone opens this view.
    static let timeout: TimeInterval = 180

    /// The classification pass touches only the Kubernetes API, so it is bounded
    /// like an ordinary kubectl call rather than like a metrics query.
    static let fastTimeout: TimeInterval = 30

    /// - Parameter metrics: false runs the classification pass only - no port
    ///   forward, no PromQL. It is what paints the Cluster tab in a couple of
    ///   seconds, and it is the only pass that still works when the metrics
    ///   store itself is the thing that is broken.
    static func analyze(context: String,
                        window: LgtmWindow,
                        metrics: Bool = true) async throws -> LgtmReport {
        guard let binary else { throw KubectlError.notFound }

        var args = ["--context", context, "--json", "--window", window.rawValue]
        if !metrics { args.append("--no-metrics") }

        let result = try await Subprocess.run(
            binary: binary,
            args: args,
            timeout: metrics ? timeout : fastTimeout,
            label: "kubectl-lgtm " + args.joined(separator: " "),
            context: context
        )

        do {
            return try decode(result.stdout)
        } catch {
            throw KubectlError.decoding(error)
        }
    }

    static func decode(_ data: Data) throws -> LgtmReport {
        let decoder = JSONDecoder()
        // Go marshals time.Time with nanoseconds ("…:21.796952Z"), which
        // .iso8601 rejects outright — it only knows .withInternetDateTime.
        // Accepting both means the wire format never has to constrain how the
        // producer stamps its clock.
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return date }
            throw KubectlError.failed("unparseable timestamp: \(s)")
        }
        return try decoder.decode(LgtmReport.self, from: data)
    }
}

#if DEBUG
extension LgtmService {
    /// One runnable check over the wire format, run from `LgtmStore.init`.
    ///
    /// The decoder is the whole contract with the Go binary and it fails at
    /// runtime, in a view, with a generic message. The two things that actually
    /// broke while building it are both covered: Go stamps `generatedAt` with
    /// nanoseconds, which `.iso8601` rejects outright, and `warning` is absent
    /// entirely on a single-cluster store.
    static func selfCheck() {
        let sample = """
        {"version":"dev","generatedAt":"2026-08-20T15:38:21.796952Z","context":"c",
         "scope":"ns/observability","source":"mimir-nginx","windowSecs":1209600,
         "components":[{"name":"mimir-distributor","namespace":"observability",
          "kind":"Deployment","product":"mimir","role":"distributor","zone":"",
          "title":"mimir/distributor","replicas":3,"readyReplicas":0,"stateful":false,
          "cpuRequestMillis":500,"cpuLimitMillis":1000,"memRequestBytes":1073741824,
          "memLimitBytes":2147483648,
          "usage":{"memP99Bytes":1,"memMaxBytes":2,"cpuP99Millis":3,"throttleRatio":0,
                   "oomContainers":0,"restarts":434,"coverageSecs":1209600,"series":[1,2]},
          "note":"","severity":"CRIT",
          "findings":[{"rule":"unhealthy","severity":"CRIT","title":"0/3 ready",
            "current":"0/3","suggested":"","rationale":"why","confidence":"high",
            "windowSecs":1209600,"snippet":"kubectl describe","evidence":[]}]}]}
        """
        guard let report = try? decode(Data(sample.utf8)) else {
            assertionFailure("LgtmReport decode failed — the --json contract moved")
            return
        }
        assert(report.warning == nil)                       // omitempty: absent, not null
        assert(report.components.count == 1)
        assert(report.components[0].healthy == false)       // 0/3 ready
        assert(report.components[0].findings.count == 1)
        assert(SeverityTag.color("CRIT") == .red)
        assert(SeverityTag.color("") == .green)             // no findings reads as OK
    }

}
#endif

extension LgtmReport {
    /// An older binary omits the field; absent means it did query the store.
    var hasMetrics: Bool { metricsAvailable ?? true }
}
