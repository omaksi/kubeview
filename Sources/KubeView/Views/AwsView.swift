import SwiftUI

struct AwsView: View {
    @EnvironmentObject var aws: AwsStore
    @EnvironmentObject var search: SearchState

    var filtered: [AwsProfile] {
        aws.profiles.searchFiltered(search) { [$0.name, $0.region ?? "", $0.kind.label] }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(count: filtered.count, label: "profiles") {
                HStack(spacing: 8) {
                    Button("Reveal in Finder") { aws.revealInFinder() }
                        .buttonStyle(.link).font(.caption)
                    Button {
                        aws.reload()
                        Task { await aws.loadContexts() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Re-read ~/.aws")
                }
            }
            if let error = aws.loadError {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(12)
                Spacer()
            } else if filtered.isEmpty {
                // An empty grid renders as blank space, which is
                // indistinguishable from the view failing to load.
                VStack(spacing: 6) {
                    Text(aws.profiles.isEmpty ? "No profiles parsed from ~/.aws"
                                              : "No profiles match the search")
                        .foregroundStyle(.secondary)
                    if !aws.profiles.isEmpty {
                        Text("\(aws.profiles.count) loaded, all filtered out")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { profile in
                            AwsProfileCard(profile: profile)
                        }
                    }.padding(12)
                }
            }
        }
    }
}

private struct AwsProfileCard: View {
    let profile: AwsProfile
    @EnvironmentObject var aws: AwsStore
    @State private var command: String = ""
    @State private var editing = false

    private var busy: Bool { aws.busy.contains(profile.name) }

    var body: some View {
        ResourceCard(ref: profile.ref) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ResourceTitle(ref: profile.ref, name: profile.name)
                    Spacer()
                    status
                }
                Text(profile.kind.label).font(.caption2).foregroundStyle(.orange)
                if let region = profile.region {
                    Text(region).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                if !profile.contexts.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("used by").font(.caption2).foregroundStyle(.secondary)
                        ForEach(profile.contexts, id: \.self) { ctx in
                            Text(ctx).font(.caption.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                actions
                if editing {
                    TextField("login command", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .onSubmit {
                            aws.setCommand(command, for: profile)
                            editing = false
                        }
                }
                if let out = aws.output[profile.name] {
                    Text(out)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
        }
        .onAppear { command = aws.command(for: profile) }
    }

    @ViewBuilder
    private var status: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else if let expiry = profile.expiry {
            // Relative style keeps counting down on its own; `aws.now` only
            // exists so the colour flips when it crosses zero.
            let expired = expiry <= aws.now
            HStack(spacing: 4) {
                Circle().fill(expired ? Color.orange : .green).frame(width: 7, height: 7)
                Text(expiry, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(expired ? .orange : .secondary)
            }
        } else {
            HStack(spacing: 4) {
                Circle().fill(Color.secondary).frame(width: 7, height: 7)
                Text("no expiry").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        // Bordered, not `.link`: link style renders as bare text that reads as
        // a label rather than a control, and it's the primary action here.
        HStack(spacing: 8) {
            Button("Log in") { aws.login(profile) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(busy)
            if profile.canLogout {
                Button("Log out") { aws.logout(profile) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busy)
            }
            Button(editing ? "Done" : "Command") {
                if editing { aws.setCommand(command, for: profile) }
                editing.toggle()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
        .padding(.top, 2)
    }
}
