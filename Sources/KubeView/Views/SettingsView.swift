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

/// One-click light/dark for the toolbar. Reads the *effective* scheme rather
/// than the stored mode, so from `.system` it flips to whichever is the opposite
/// of what you're currently looking at — which is what a single button should do.
/// The three-way choice, including returning to System, stays in Settings.
struct AppearanceToggle: View {
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    @Environment(\.colorScheme) private var scheme

    private var isDark: Bool { scheme == .dark }

    var body: some View {
        Button {
            appearance = isDark ? .light : .dark
        } label: {
            Image(systemName: isDark ? "sun.max" : "moon")
        }
        .help(isDark ? "Switch to light appearance" : "Switch to dark appearance")
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ClusterSettings()
                .tabItem { Label("Clusters", systemImage: "square.stack.3d.up") }
            AwsView()
                .tabItem { Label("AWS", systemImage: "key.horizontal") }
            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "ladybug") }
            FeedbackSettings()
                .tabItem { Label("Feedback", systemImage: "exclamationmark.bubble") }
        }
        // Wider and taller than a settings window wants to be, because AWS and
        // Diagnostics are panes, not forms.
        // ponytail: Diagnostics is a live log and really wants its own window
        // you park beside the app. Promote it if tailing here feels cramped.
        .frame(width: 720, height: 500)
    }
}

private struct GeneralSettings: View {
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

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
        }
        .formStyle(.grouped)
    }
}

/// Names are a display layer over the kubeconfig, which is never rewritten.
private struct ClusterSettings: View {
    @EnvironmentObject var manager: ClusterManager
    @EnvironmentObject var names: ClusterNameStore

    var body: some View {
        Form {
            Section {
                if manager.availableContexts.isEmpty {
                    Text("No contexts in kubeconfig").foregroundStyle(.secondary)
                }
                ForEach(manager.availableContexts, id: \.self) { ctx in
                    VStack(alignment: .leading, spacing: 2) {
                        TextField(
                            ClusterNameStore.shortened(ctx),
                            text: Binding(get: { names.alias(for: ctx) },
                                          set: { names.set($0, for: ctx) })
                        )
                        Text(ctx)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(ctx)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Cluster names")
            } footer: {
                Text("Shown in the cluster bar and menu bar instead of the context name. "
                     + "Clear a name to fall back to the context. Your kubeconfig is never "
                     + "modified — kubectl still uses the real context name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FeedbackSettings: View {
    @State private var token = ""
    @State private var tokenSaved = false

    var body: some View {
        Form {
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
