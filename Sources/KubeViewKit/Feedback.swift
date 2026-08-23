import Foundation
import Security
import KubeModel
import KubeClient
import KubeUI

enum FeedbackError: LocalizedError {
    case noToken
    case unauthorized
    case noAccess
    case http(Int, String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No GitHub token configured — add one in Settings, or use Copy Report and paste it into an issue yourself."
        case .unauthorized:
            return "GitHub rejected the token. It may be expired or mistyped."
        case .noAccess:
            return "That token can't open issues on omaksi/kubeview. It needs Issues: write (fine-grained) or public_repo (classic)."
        case .http(let code, let message):
            return "GitHub returned \(code): \(message)"
        case .malformedResponse:
            return "GitHub accepted the report but returned something unexpected."
        }
    }
}

/// A report about to leave the machine. Built once, shown to the user verbatim,
/// then sent — the string previewed in the sheet is the string transmitted, so
/// there is no gap between what was reviewed and what was published.
struct FeedbackReport {
    let title: String
    let body: String

    /// GitHub rejects bodies over 65536 characters. Trim the log rather than the
    /// user's own description, and say so in place so a truncated report never
    /// reads as a complete one.
    static let maxBody = 60_000

    static func build(summary: String, detail: String, diagnostics: String) -> FeedbackReport {
        var body = ""
        if !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body += detail + "\n\n"
        }
        body += "<details>\n<summary>Diagnostics</summary>\n\n"

        let room = maxBody - body.count - 32
        if diagnostics.count > room, room > 0 {
            let kept = String(diagnostics.suffix(room))
            body += "_Earlier entries omitted — log exceeded GitHub's size limit._\n\n" + kept
        } else {
            body += diagnostics
        }
        body += "\n</details>"
        return FeedbackReport(title: summary, body: body)
    }
}

struct GitHubIssueTransport {
    let owner = "omaksi"
    let repo = "kubeview"

    func send(_ report: FeedbackReport, token: String) async throws -> URL {
        guard !token.isEmpty else { throw FeedbackError.noToken }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/issues")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("KubeView", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": report.title,
            "body": report.body,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FeedbackError.malformedResponse }
        switch http.statusCode {
        case 201:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let urlString = json["html_url"] as? String,
                  let url = URL(string: urlString) else { throw FeedbackError.malformedResponse }
            return url
        case 401:
            throw FeedbackError.unauthorized
        case 403, 404:
            // GitHub returns 404 rather than 403 when a token can't see the repo,
            // to avoid leaking whether it exists.
            throw FeedbackError.noAccess
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["message"] as? String } ?? "unknown error"
            throw FeedbackError.http(http.statusCode, message)
        }
    }
}

/// Tokens go in the Keychain, never `UserDefaults` — a plist is world-readable
/// within the user's account and ends up in backups.
enum Keychain {
    static let service = "com.omaksi.kubeview"
    static let githubTokenAccount = "github-token"

    static func set(_ value: String, account: String) {
        delete(account)
        guard !value.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
