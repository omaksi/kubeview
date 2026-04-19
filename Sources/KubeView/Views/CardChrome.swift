import SwiftUI

/// Wraps a card body with subtle left accent stripe (resource kind) and an
/// emoji overlay. Right-click opens the emoji picker. Pass `navigable: true`
/// to show a chevron affordance indicating a drill-down is available.
struct ResourceCard<Content: View>: View {
    let ref: ResourceRef
    let navigable: Bool
    let dimmed: Bool
    @EnvironmentObject var emojis: EmojiStore
    @EnvironmentObject var store: ClusterStore
    @State private var describeOpen = false
    @State private var hovering = false
    @State private var emojiInput: String = ""
    @FocusState private var emojiFieldFocused: Bool
    let content: Content

    init(ref: ResourceRef, navigable: Bool = false, dimmed: Bool = false, @ViewBuilder content: () -> Content) {
        self.ref = ref
        self.navigable = navigable
        self.dimmed = dimmed
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(ref.kind.accent)
                .frame(width: 3)
            content
                .padding(12)
                .padding(.trailing, navigable ? 22 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if navigable {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 10)
                            .opacity(hovering ? 1.0 : 0.6)
                    }
                }
        }
        .background(.quaternary.opacity(hovering && navigable ? 0.55 : 0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .opacity(dimmed ? 0.5 : 1.0)
        .saturation(dimmed ? 0.3 : 1.0)
        .onHover { hovering = $0 }
        .overlay(alignment: .topLeading) {
            // Hidden field that receives emoji from the system character palette.
            TextField("", text: $emojiInput)
                .textFieldStyle(.plain)
                .focused($emojiFieldFocused)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)
                .onChange(of: emojiInput) { _, new in
                    guard !new.isEmpty else { return }
                    emojis.set(String(new.prefix(1)), for: ref)
                    emojiInput = ""
                    emojiFieldFocused = false
                }
        }
        .contextMenu {
            if ref.kind.kubectlResource != nil {
                Button("Describe…") { describeOpen = true }
                Divider()
            }
            Button("Set Emoji…") {
                emojiInput = ""
                emojiFieldFocused = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NSApp.orderFrontCharacterPalette(nil)
                }
            }
            if emojis.emoji(for: ref) != nil {
                Button("Clear Emoji", role: .destructive) { emojis.set(nil, for: ref) }
            }
        }
        .sheet(isPresented: $describeOpen) {
            DescribeSheet(ref: ref, context: store.context, isOpen: $describeOpen)
        }
    }
}

/// Renders the emoji (if one is assigned to `ref`) followed by the resource name.
/// Use at the start of each card body's title HStack so emojis are visible
/// regardless of what else is in the header.
struct ResourceTitle: View {
    let ref: ResourceRef
    let name: String
    var font: Font = .system(.callout, design: .monospaced).weight(.semibold)
    @EnvironmentObject var emojis: EmojiStore

    var body: some View {
        HStack(spacing: 6) {
            if let e = emojis.emoji(for: ref) {
                Text(e).font(.system(size: 16))
            }
            Text(name)
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

@MainActor
final class DescribeLoader: ObservableObject {
    @Published var text = ""
    @Published var loading = false
    @Published var error: String?
    private let kubectl: KubectlService

    init(context: String) {
        self.kubectl = KubectlService(context: context)
    }

    func load(kind: String, name: String, namespace: String?) async {
        loading = true
        defer { loading = false }
        do {
            text = try await kubectl.describe(kind: kind, name: name, namespace: namespace)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DescribeSheet: View {
    let ref: ResourceRef
    let context: String
    @Binding var isOpen: Bool
    @StateObject private var loader: DescribeLoader
    @State private var filter = ""

    init(ref: ResourceRef, context: String, isOpen: Binding<Bool>) {
        self.ref = ref
        self.context = context
        self._isOpen = isOpen
        _loader = StateObject(wrappedValue: DescribeLoader(context: context))
    }

    private var filtered: String {
        guard !filter.isEmpty else { return loader.text }
        let q = filter.lowercased()
        return loader.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.lowercased().contains(q) }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: ref.kind.icon).foregroundStyle(ref.kind.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Describe \(ref.kind.title)").font(.headline)
                    Text(ref.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    if loader.loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(loader.loading)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(loader.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(loader.text.isEmpty)
                .help("Copy all")
                Button("Close") { isOpen = false }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Filter", text: $filter).textFieldStyle(.plain)
            }
            .padding(8)
            .background(.bar)

            if let err = loader.error {
                Text(err).font(.caption.monospaced()).foregroundStyle(.red).padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView([.vertical, .horizontal]) {
                Text(filtered)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 720, minHeight: 520)
        .task { await reload() }
    }

    private func reload() async {
        guard let kind = ref.kind.kubectlResource else { return }
        await loader.load(kind: kind, name: ref.resourceName, namespace: ref.namespace)
    }
}

