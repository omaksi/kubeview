import Foundation

enum KubectlError: Error, LocalizedError {
    case notFound
    case failed(String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .notFound: return "kubectl not found on PATH"
        case .failed(let s): return s
        case .decoding(let e): return "decode error: \(e)"
        }
    }
}

actor KubectlService {
    private let binary: String
    let context: String?

    init(context: String? = nil) {
        let candidates = [
            "/opt/homebrew/bin/kubectl",
            "/usr/local/bin/kubectl",
            "/usr/bin/kubectl"
        ]
        self.binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "kubectl"
        self.context = context
    }

    /// Every kubectl invocation is bounded three ways, because each covers a
    /// different hang:
    ///
    /// - null stdin — kubectl prompts for basic-auth credentials when a context
    ///   has none, and a GUI app has nobody to answer. Turns a hang into an
    ///   instant EOF failure.
    /// - `--request-timeout` — bounds one API request. It is reliable for
    ///   `get --raw` (measured 5.2s for a 5s setting against a black-holed IP)
    ///   but NOT for `get <resource>`, which runs API discovery first: a 10s
    ///   setting was still running past 15s. Never rely on it alone.
    /// - the watchdog — the backstop that covers the discovery overrun above,
    ///   and anything else kubectl does outside a single request. Verified
    ///   killing a wedged `get pods` at timeout × 1.5.
    ///
    /// `nonisolated` on purpose: the previous version blocked inside the actor,
    /// so `refresh()`'s `async let` batch serialised and each call pinned a
    /// cooperative thread. Only immutable state is touched here.
    nonisolated func run(_ args: [String], timeout: TimeInterval = 15) async throws -> Data {
        var args = args
        if let ctx = context, !args.contains("--context") {
            args = ["--context", ctx] + args
        }
        if !args.contains(where: { $0.hasPrefix("--request-timeout") }) {
            args.append("--request-timeout=\(Int(timeout))s")
        }
        let display = "kubectl " + args.joined(separator: " ")
        let started = Date()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        // Ensure PATH includes Homebrew for exec auth plugins (aws, gke-gcloud-auth-plugin, etc.)
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = env["PATH"].map { "\($0):\(extra)" } ?? extra
        process.environment = env

        do { try process.run() } catch {
            LogStore.record(.error, "kubectl not executable", context: context, detail: binary)
            throw KubectlError.notFound
        }

        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1.5 * 1_000_000_000))
            guard process.isRunning else { return }
            LogStore.record(.warn, "killing hung kubectl after \(Int(timeout * 1.5))s",
                            context: context, detail: display)
            process.terminate()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        defer { watchdog.cancel() }

        // readToEnd/waitUntilExit block; keep them off the cooperative pool.
        let (data, errData) = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let out = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                let err = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                process.waitUntilExit()
                cont.resume(returning: (out, err))
            }
        }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        guard process.terminationStatus == 0 else {
            let stderrText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let killed = process.terminationReason == .uncaughtSignal
            let msg = killed
                ? "timed out after \(Int(timeout * 1.5))s — cluster unreachable?"
                : (stderrText.isEmpty ? "exit \(process.terminationStatus)" : stderrText)
            LogStore.record(.error, "\(display) failed in \(ms)ms", context: context, detail: msg)
            throw KubectlError.failed(msg)
        }
        LogStore.record(.debug, "\(display) → \(data.count)B in \(ms)ms", context: context)
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw KubectlError.decoding(error) }
    }

    // MARK: - API

    func currentContext() async throws -> String {
        let data = try await run(["config", "current-context"])
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func serverVersion() async throws -> String? {
        let data = try await run(["version", "-o", "json"])
        struct V: Decodable { let serverVersion: Inner?; struct Inner: Decodable { let gitVersion: String? } }
        return (try? JSONDecoder().decode(V.self, from: data))?.serverVersion?.gitVersion
    }

    func contexts() async throws -> [KubeContext] {
        let data = try await run(["config", "get-contexts", "-o", "name"])
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").map { KubeContext(name: String($0)) }
    }


    func pods(namespace: String? = nil, allNamespaces: Bool = true) async throws -> [Pod] {
        var args = ["get", "pods", "-o", "json"]
        if allNamespaces { args.append("--all-namespaces") }
        else if let ns = namespace { args.append(contentsOf: ["-n", ns]) }
        let data = try await run(args)
        return try decode(PodList.self, from: data).items
    }

    func nodes() async throws -> [Node] {
        let data = try await run(["get", "nodes", "-o", "json"])
        return try decode(NodeList.self, from: data).items
    }

    func namespaces() async throws -> [Namespace] {
        let data = try await run(["get", "namespaces", "-o", "json"])
        return try decode(NamespaceList.self, from: data).items
    }

    func ingresses() async throws -> [Ingress] {
        let data = try await run(["get", "ingress", "--all-namespaces", "-o", "json"])
        return try decode(IngressList.self, from: data).items
    }

    func services() async throws -> [Service] {
        let data = try await run(["get", "services", "--all-namespaces", "-o", "json"])
        return try decode(ServiceList.self, from: data).items
    }

    func secrets() async throws -> [Secret] {
        let data = try await run(["get", "secrets", "--all-namespaces", "-o", "json"])
        return try decode(SecretList.self, from: data).items
    }

    func pvcs() async throws -> [PVC] {
        let data = try await run(["get", "pvc", "--all-namespaces", "-o", "json"])
        return try decode(PVCList.self, from: data).items
    }

    func storageClasses() async throws -> [StorageClass] {
        let data = try await run(["get", "storageclasses", "-o", "json"])
        return try decode(StorageClassList.self, from: data).items
    }

    func networkPolicies() async throws -> [NetworkPolicy] {
        let data = try await run(["get", "networkpolicies", "--all-namespaces", "-o", "json"])
        return try decode(NetworkPolicyList.self, from: data).items
    }

    func serviceAccounts() async throws -> [ServiceAccount] {
        let data = try await run(["get", "serviceaccounts", "--all-namespaces", "-o", "json"])
        return try decode(ServiceAccountList.self, from: data).items
    }

    func deployments() async throws -> [Deployment] {
        let data = try await run(["get", "deployments", "--all-namespaces", "-o", "json"])
        return try decode(DeploymentList.self, from: data).items
    }

    func statefulSets() async throws -> [StatefulSet] {
        let data = try await run(["get", "statefulsets", "--all-namespaces", "-o", "json"])
        return try decode(StatefulSetList.self, from: data).items
    }

    func replicaSets() async throws -> [ReplicaSet] {
        let data = try await run(["get", "replicasets", "--all-namespaces", "-o", "json"])
        return try decode(ReplicaSetList.self, from: data).items
    }

    func jobs() async throws -> [KubeJob] {
        let data = try await run(["get", "jobs", "--all-namespaces", "-o", "json"])
        return try decode(JobList.self, from: data).items
    }

    func cronJobs() async throws -> [CronJob] {
        let data = try await run(["get", "cronjobs", "--all-namespaces", "-o", "json"])
        return try decode(CronJobList.self, from: data).items
    }

    func daemonSets() async throws -> [DaemonSet] {
        let data = try await run(["get", "daemonsets", "--all-namespaces", "-o", "json"])
        return try decode(DaemonSetList.self, from: data).items
    }

    func configMaps() async throws -> [ConfigMap] {
        let data = try await run(["get", "configmaps", "--all-namespaces", "-o", "json"])
        return try decode(ConfigMapList.self, from: data).items
    }

    func hpas() async throws -> [HPA] {
        let data = try await run(["get", "hpa", "--all-namespaces", "-o", "json"])
        return try decode(HPAList.self, from: data).items
    }

    /// Cluster-wide events. Expensive on busy clusters; fetch on demand.
    func allEvents(warningsOnly: Bool = false) async throws -> [KubeEvent] {
        var args = ["get", "events", "--all-namespaces", "-o", "json"]
        if warningsOnly { args.append(contentsOf: ["--field-selector", "type=Warning"]) }
        let data = try await run(args)
        return try decode(EventList.self, from: data).items
            .sorted { ($0.lastTimestamp ?? "") > ($1.lastTimestamp ?? "") }
    }

    func logs(namespace: String, pod: String, container: String?,
              tailLines: Int = 500, previous: Bool = false) async throws -> String {
        var args = ["logs", pod, "-n", namespace, "--tail=\(tailLines)"]
        if let c = container { args.append(contentsOf: ["-c", c]) }
        if previous { args.append("--previous") }
        let data = try await run(args)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func describe(namespace: String, pod: String) async throws -> String {
        try await describe(kind: "pod", name: pod, namespace: namespace)
    }

    func describe(kind: String, name: String, namespace: String?) async throws -> String {
        var args = ["describe", kind, name]
        if let ns = namespace { args.append(contentsOf: ["-n", ns]) }
        let data = try await run(args)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func events(namespace: String, podName: String) async throws -> [KubeEvent] {
        let selector = "involvedObject.kind=Pod,involvedObject.name=\(podName)"
        let data = try await run([
            "get", "events",
            "-n", namespace,
            "--field-selector", selector,
            "-o", "json"
        ])
        let list = try decode(EventList.self, from: data).items
        return list.sorted { (a, b) in
            (a.lastTimestamp ?? "") > (b.lastTimestamp ?? "")
        }
    }

    /// Returns nil if metrics-server isn't installed / reachable.
    func nodeMetrics() async -> [NodeMetrics]? {
        guard let data = try? await run(["get", "--raw", "/apis/metrics.k8s.io/v1beta1/nodes"]) else {
            return nil
        }
        return (try? JSONDecoder().decode(NodeMetricsList.self, from: data))?.items
    }

    func podMetrics() async -> [PodMetrics]? {
        guard let data = try? await run(["get", "--raw", "/apis/metrics.k8s.io/v1beta1/pods"]) else {
            return nil
        }
        return (try? JSONDecoder().decode(PodMetricsList.self, from: data))?.items
    }
}

