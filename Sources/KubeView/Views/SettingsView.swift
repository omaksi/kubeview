import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// nil means "no preference", which is how SwiftUI spells follow-the-system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

struct SettingsView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    @State private var token = ""
    @State private var tokenSaved = false

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("System follows your macOS appearance setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("GitHub token", text: $token)
                HStack {
                    Button("Save") {
                        Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines),
                                     account: Keychain.githubTokenAccount)
                        tokenSaved = true
                    }
                    .controlSize(.small)
                    .disabled(token.isEmpty)
                    Button("Remove") {
                        Keychain.delete(Keychain.githubTokenAccount)
                        token = ""
                        tokenSaved = false
                    }
                    .controlSize(.small)
                    Spacer()
                    if tokenSaved {
                        Label("Stored in Keychain", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            } header: {
                Text("Feedback")
            } footer: {
                Text("Needed to open issues from Report Feedback. Use a fine-grained token "
                     + "scoped to omaksi/kubeview with Issues: write, or a classic token with "
                     + "public_repo. Stored in your Keychain, never in preferences. Without one, "
                     + "Report Feedback still lets you copy the payload and paste it yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .onAppear {
            // Show that a token exists without ever displaying it.
            tokenSaved = Keychain.get(Keychain.githubTokenAccount)?.isEmpty == false
            if tokenSaved { token = "" }
        }
    }
}

extension AppearanceMode {
    static let storageKey = "kubeview.appearance"
}
