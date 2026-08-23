import Foundation
import SwiftUI

enum AwsAuthKind: Hashable {
    case sso(session: String)
    case assumeRole(source: String)
    case temporary
    case staticKeys
    case unknown

    var label: String {
        switch self {
        case .sso(let s):        return "SSO · \(s)"
        case .assumeRole(let s): return "assume-role · \(s)"
        case .temporary:         return "temporary"
        case .staticKeys:        return "static keys"
        case .unknown:           return "unknown"
        }
    }
}

struct AwsProfile: Identifiable, Hashable {
    var name: String
    var region: String?
    var kind: AwsAuthKind
    var expiry: Date?
    var contexts: [String] = []

    var id: String { name }
    var ref: ResourceRef { ResourceRef(kind: .awsProfile, key: name) }
    var isExpired: Bool { expiry.map { $0 <= Date() } ?? false }

    /// Only the SSO form is derivable from disk. Everything else was written by
    /// an external tool (saml2aws, aws-vault, a script) whose invocation leaves
    /// no trace in ~/.aws — hence the editable override in `AwsStore.command`.
    var defaultLoginCommand: String {
        switch kind {
        case .sso(let session): return "aws sso login --sso-session \(session)"
        default:                return "saml2aws login -a default -p \(name)"
        }
    }

    var canLogout: Bool { if case .sso = kind { return true }; return false }
}

// MARK: - Parsing

enum AwsConfigParser {
    /// Section name -> key/value, sections keeping their raw header
    /// ("profile foo", "sso-session bar", "default").
    /// ponytail: flat only — nested sub-settings (`s3 =` + indented keys) come
    /// back as ordinary keys. Nothing here reads them.
    static func ini(_ text: String) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        var current: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                out[current!] = out[current!] ?? [:]
                continue
            }
            guard let section = current, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            out[section, default: [:]][key] = value
        }
        return out
    }

    /// aws-cli writes `2026-08-17T13:18:20Z`; older releases wrote `…UTC`, and
    /// saml2aws writes an offset (`+02:00`) with no fractional seconds.
    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        if s.hasSuffix("UTC") {
            let z = s.replacingOccurrences(of: "UTC", with: "Z")
            if let d = f.date(from: z) { return d }
        }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// SSO start URLs are compared across two files that don't agree on
    /// trailing punctuation (`…/start` vs `…/start/#`).
    static func normalizeStartURL(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "#/ "))
    }

    #if DEBUG
    /// ponytail: the one runnable check. Asserts fire in debug builds, which is
    /// where this parser gets edited. No test target, no fixtures on disk.
    static func selfCheck() {
        let cfg = ini("""
        [default]
        region = eu-central-1
        # comment
        [profile p1]
        sso_session = sess
        sso_account_id = 123

        [sso-session sess]
        sso_start_url = https://x.awsapps.com/start/#
        """)
        assert(cfg["default"]?["region"] == "eu-central-1")
        assert(cfg["profile p1"]?["sso_session"] == "sess")
        assert(cfg["sso-session sess"]?["sso_start_url"] == "https://x.awsapps.com/start/#")
        assert(cfg.count == 3, "comment or blank line leaked a section")

        assert(date("2026-08-17T13:18:20Z") != nil)
        assert(date("2026-07-08T14:55:59+02:00") != nil)
        assert(date("2026-08-17T13:18:20UTC") != nil)
        assert(date("nonsense") == nil)

        assert(normalizeStartURL("https://x.awsapps.com/start/#") == normalizeStartURL("https://x.awsapps.com/start"))
    }
    #endif
}

// MARK: - Store

@MainActor
final class AwsStore: ObservableObject {
    @Published private(set) var profiles: [AwsProfile] = []
    @Published private(set) var loadError: String?
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var output: [String: String] = [:]
    /// Bumped on a timer so expiry styling flips without a user interaction.
    @Published private(set) var now = Date()

    /// Fired after credentials on disk change, so faulted clusters can retry.
    /// Async on purpose: the caller stays "busy" until the clusters have
    /// actually reconnected, which is the slow half of a login.
    var onCredentialsChanged: (() async -> Void)?

    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws")
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var ticker: Timer?

    init() {
        #if DEBUG
        AwsConfigParser.selfCheck()
        #endif
        reload()
        watch()
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        Task { await loadContexts() }
    }

    deinit { watcher?.cancel() }

    // MARK: Login command (editable per profile)

    /// The profile a kube context authenticates with, if the kubeconfig names
    /// one. Nil for contexts that assume a role without naming a profile.
    func profile(forContext context: String) -> AwsProfile? {
        profiles.first { $0.contexts.contains(context) }
    }

    func isBusy(_ profile: AwsProfile) -> Bool { busy.contains(profile.name) }

    func command(for profile: AwsProfile) -> String {
        UserDefaults.standard.string(forKey: Self.commandKey(profile.name))
            ?? profile.defaultLoginCommand
    }

    func setCommand(_ command: String, for profile: AwsProfile) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == profile.defaultLoginCommand {
            UserDefaults.standard.removeObject(forKey: Self.commandKey(profile.name))
        } else {
            UserDefaults.standard.set(trimmed, forKey: Self.commandKey(profile.name))
        }
        objectWillChange.send()
    }

    private static func commandKey(_ name: String) -> String { "kubeview.awsLogin.\(name)" }

    // MARK: Actions

    func login(_ profile: AwsProfile) { run(command(for: profile), for: profile.name) }

    func logout(_ profile: AwsProfile) {
        guard case .sso(let session) = profile.kind else { return }
        run("aws sso logout --sso-session \(session)", for: profile.name)
    }

    private func run(_ command: String, for name: String) {
        guard !busy.contains(name) else { return }
        busy.insert(name)
        output[name] = "running: \(command)"
        LogStore.record(.info, "aws: \(command)")
        Task {
            // `sh` blocks, so it runs off the main actor; everything after it
            // is back on the main actor because the store is @MainActor.
            let (code, text) = await Task.detached { Self.sh(command, timeout: 300) }.value
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            output[name] = trimmed.isEmpty ? (code == 0 ? "done" : "exited \(code)") : trimmed
            LogStore.record(code == 0 ? .info : .error, "aws login exited \(code)", detail: trimmed)
            reload()
            if code == 0 {
                // The process exiting means credentials exist, not that the
                // cluster is back — that costs a preflight plus ~18 kubectl
                // calls. Stay busy through it so the pill keeps its spinner
                // instead of going quiet at the slowest moment.
                output[name] = "credentials updated — reconnecting…"
                await onCredentialsChanged?()
            }
            busy.remove(name)
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.selectFile(dir.appendingPathComponent("config").path,
                                      inFileViewerRootedAtPath: dir.path)
    }

    /// Runs through `sh -c` so the editable command keeps normal shell quoting.
    /// Bounded the same three ways as `KubectlService.run`: null stdin (a login
    /// that wants a TTY prompt fails fast instead of hanging a GUI app),
    /// a timeout, and a kill.
    nonisolated private static func sh(_ command: String, timeout: TimeInterval) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]

        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = env["PATH"].map { "\($0):\(extra)" } ?? extra
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice

        do { try p.run() } catch { return (-1, "failed to launch: \(error.localizedDescription)") }

        let killer = DispatchWorkItem {
            guard p.isRunning else { return }
            p.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: Loading

    func reload() {
        let config = read("config").map(AwsConfigParser.ini) ?? [:]
        let credentials = read("credentials").map(AwsConfigParser.ini) ?? [:]
        if config.isEmpty && credentials.isEmpty {
            loadError = "No profiles found in \(dir.path)"
        } else {
            loadError = nil
        }

        let ssoExpiry = ssoCacheExpiry()
        let previousContexts = Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, $0.contexts) })

        var names = Set(credentials.keys)
        var settings: [String: [String: String]] = credentials
        for (section, values) in config {
            guard section == "default" || section.hasPrefix("profile ") else { continue }
            let name = section == "default" ? "default" : String(section.dropFirst("profile ".count))
            names.insert(name)
            settings[name] = settings[name, default: [:]].merging(values) { _, new in new }
        }

        profiles = names.sorted().map { name in
            let values = settings[name] ?? [:]
            let kind = classify(values, credentials: credentials[name])
            var expiry: Date?
            if case .sso(let session) = kind {
                expiry = config["sso-session \(session)"]?["sso_start_url"]
                    .map(AwsConfigParser.normalizeStartURL)
                    .flatMap { ssoExpiry[$0] }
            } else if let raw = credentials[name]?["x_security_token_expires"] {
                expiry = AwsConfigParser.date(raw)
            }
            return AwsProfile(name: name,
                              region: values["region"],
                              kind: kind,
                              expiry: expiry,
                              contexts: previousContexts[name] ?? [])
        }
    }

    private func classify(_ values: [String: String], credentials: [String: String]?) -> AwsAuthKind {
        if let session = values["sso_session"] { return .sso(session: session) }
        if values["sso_start_url"] != nil { return .sso(session: "inline") }
        if let source = values["source_profile"] { return .assumeRole(source: source) }
        if credentials?["x_security_token_expires"] != nil { return .temporary }
        if credentials?["aws_access_key_id"] != nil { return .staticKeys }
        return .unknown
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    private struct SsoToken: Decodable {
        let startUrl: String?
        let expiresAt: String?
    }

    /// Normalized start URL -> token expiry. Client-registration files in the
    /// same directory carry no startUrl and are skipped.
    private func ssoCacheExpiry() -> [String: Date] {
        let cache = dir.appendingPathComponent("sso/cache")
        let files = (try? FileManager.default.contentsOfDirectory(at: cache,
                                                                  includingPropertiesForKeys: nil)) ?? []
        var out: [String: Date] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let token = try? JSONDecoder().decode(SsoToken.self, from: data),
                  let url = token.startUrl,
                  let expires = token.expiresAt.flatMap(AwsConfigParser.date) else { continue }
            let key = AwsConfigParser.normalizeStartURL(url)
            // Several cached tokens can share a start URL; the newest wins.
            if let existing = out[key], existing > expires { continue }
            out[key] = expires
        }
        return out
    }

    /// Which kube contexts authenticate with which profile, read from the
    /// kubeconfig exec blocks. A context that assumes a role without naming a
    /// profile (`--role` off `[default]`) can't be attributed and is skipped.
    func loadContexts() async {
        guard let data = try? await KubectlService(context: nil)
            .run(["config", "view", "-o", "json"], timeout: 10),
              let config = try? JSONDecoder().decode(KubeConfigView.self, from: data) else { return }

        var profileForUser: [String: String] = [:]
        for user in config.users ?? [] {
            guard let exec = user.user.exec else { continue }
            if let env = exec.env?.first(where: { $0.name == "AWS_PROFILE" }) {
                profileForUser[user.name] = env.value
            } else if let args = exec.args, let i = args.firstIndex(of: "--profile"), i + 1 < args.count {
                profileForUser[user.name] = args[i + 1]
            }
        }

        var byProfile: [String: [String]] = [:]
        for ctx in config.contexts ?? [] {
            guard let profile = profileForUser[ctx.context.user] else { continue }
            byProfile[profile, default: []].append(ctx.name)
        }
        for i in profiles.indices {
            profiles[i].contexts = (byProfile[profiles[i].name] ?? []).sorted()
        }
    }

    private struct KubeConfigView: Decodable {
        struct Context: Decodable {
            struct Inner: Decodable { let user: String }
            let name: String
            let context: Inner
        }
        struct User: Decodable {
            struct Detail: Decodable {
                struct Exec: Decodable {
                    struct EnvVar: Decodable { let name: String; let value: String }
                    let env: [EnvVar]?
                    let args: [String]?
                }
                let exec: Exec?
            }
            let name: String
            let user: Detail
        }
        let contexts: [Context]?
        let users: [User]?
    }

    // MARK: Watching

    /// Watches ~/.aws itself, which covers the credentials file every 1-hour
    /// SAML session rewrites. SSO writes land in ~/.aws/sso/cache and don't
    /// touch this directory — those are picked up by the login handler instead.
    private func watch() {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .attrib], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// A single `aws`/`saml2aws` run rewrites the credentials file several
    /// times; without coalescing each write would kick a full cluster refresh.
    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reload()
            Task { await self.onCredentialsChanged?() }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
