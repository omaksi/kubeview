import Foundation
import KubeModel

/// Running an external CLI, with the three hang defences every one of them needs.
///
/// This was `KubectlService.run` until a second tool (`kubectl-lgtm`) needed the
/// same treatment. The defences below were each added for an observed hang, so
/// duplicating them for tool number two would have meant rediscovering them.
public enum Subprocess {
    /// Homebrew first: `aws`, `gke-gcloud-auth-plugin` and friends live there,
    /// and a GUI app inherits launchd's PATH, not the shell's. Every exec-based
    /// kubeconfig auth plugin fails without this.
    static let extraPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    public static func locate(_ names: [String]) -> String? {
        names.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Every invocation is bounded three ways, because each covers a different
    /// hang:
    ///
    /// - null stdin — kubectl prompts for basic-auth credentials when a context
    ///   has none, and a GUI app has nobody to answer. Turns a hang into an
    ///   instant EOF failure.
    /// - the tool's own request timeout — the caller adds it (kubectl gets
    ///   `--request-timeout`). It bounds one API request, which is not the same
    ///   as bounding the process.
    /// - the watchdog below — the backstop for everything the tool does outside
    ///   a single request: `kubectl get <resource>` runs API discovery first and
    ///   overran a 10s request timeout past 15s. Never rely on the tool alone.
    ///
    /// `stderr` comes back alongside stdout on success rather than being
    /// discarded, because a tool can report progress there and still exit 0.
    public static func run(binary: String,
                    args: [String],
                    timeout: TimeInterval,
                    label: String,
                    context: String?) async throws -> (stdout: Data, stderr: String) {
        let started = Date()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = env["PATH"].map { "\($0):\(extraPATH)" } ?? extraPATH
        process.environment = env

        do { try process.run() } catch {
            LogSink.record(.error, "\(label) not executable", context: context, detail: binary)
            throw KubectlError.notFound
        }

        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1.5 * 1_000_000_000))
            guard process.isRunning else { return }
            LogSink.record(.warn, "killing hung \(label) after \(Int(timeout * 1.5))s",
                            context: context, detail: label)
            process.terminate()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        defer { watchdog.cancel() }

        // readToEnd/waitUntilExit block; keep them off the cooperative pool.
        let (data, errData) = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let o = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                let e = (try? err.fileHandleForReading.readToEnd()) ?? Data()
                process.waitUntilExit()
                cont.resume(returning: (o, e))
            }
        }

        let stderrText = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ms = Int(Date().timeIntervalSince(started) * 1000)

        guard process.terminationStatus == 0 else {
            let killed = process.terminationReason == .uncaughtSignal
            let msg = killed
                ? "timed out after \(Int(timeout * 1.5))s — cluster unreachable?"
                : (stderrText.isEmpty ? "exit \(process.terminationStatus)" : stderrText)
            LogSink.record(.error, "\(label) failed in \(ms)ms", context: context, detail: msg)
            throw KubectlError.failed(msg)
        }

        LogSink.record(.debug, "\(label) → \(data.count)B in \(ms)ms", context: context)
        return (data, stderrText)
    }
}
