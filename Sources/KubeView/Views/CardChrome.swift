import SwiftUI

/// Wraps a card body with subtle left accent stripe (resource kind) and an
/// emoji overlay. Right-click opens the emoji picker. Pass `navigable: true`
/// to show a chevron affordance indicating a drill-down is available.
struct ResourceCard<Content: View>: View {
    let ref: ResourceRef
    let navigable: Bool
    @EnvironmentObject var emojis: EmojiStore
    @EnvironmentObject var store: ClusterStore
    @State private var pickerOpen = false
    @State private var describeOpen = false
    @State private var hovering = false
    let content: Content

    init(ref: ResourceRef, navigable: Bool = false, @ViewBuilder content: () -> Content) {
        self.ref = ref
        self.navigable = navigable
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(ref.kind.accent)
                .frame(width: 3)
            ZStack(alignment: .topTrailing) {
                content
                    .padding(12)
                    .padding(.trailing, navigable ? 10 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let e = emojis.emoji(for: ref) {
                    Text(e)
                        .font(.system(size: 18))
                        .padding(6)
                }
                if navigable {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 10)
                        .frame(maxHeight: .infinity)
                        .opacity(hovering ? 1.0 : 0.6)
                }
            }
        }
        .background(.quaternary.opacity(hovering && navigable ? 0.55 : 0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .contextMenu {
            if ref.kind.kubectlResource != nil {
                Button("Describe…") { describeOpen = true }
                Divider()
            }
            Button("Set Emoji…") { pickerOpen = true }
            if emojis.emoji(for: ref) != nil {
                Button("Clear Emoji", role: .destructive) { emojis.set(nil, for: ref) }
            }
        }
        .popover(isPresented: $pickerOpen, arrowEdge: .top) {
            EmojiPicker(ref: ref, isOpen: $pickerOpen).environmentObject(emojis)
        }
        .sheet(isPresented: $describeOpen) {
            DescribeSheet(ref: ref, context: store.context, isOpen: $describeOpen)
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

struct EmojiPicker: View {
    let ref: ResourceRef
    @Binding var isOpen: Bool
    @EnvironmentObject var emojis: EmojiStore
    @State private var text: String = ""

    // Presets by kind — quick pick
    private var presets: [String] {
        switch ref.kind {
        case .namespace:      return ["📦", "🏷", "🧩", "🧪", "🚀", "🔒", "💼", "🌐", "🧰", "🛠", "💾", "📡"]
        case .pod:            return ["🐳", "🧊", "🔧", "⚙️", "🚦", "🔥", "💤", "🎯"]
        case .node:           return ["🖥", "🧱", "🗄", "⚡️", "🌡", "💪"]
        case .service:        return ["🔌", "🧵", "🔁", "🧭", "📮", "🛰"]
        case .ingress:        return ["🌐", "🔐", "🚪", "📥", "🧱", "🛣"]
        case .secret:         return ["🔑", "🔐", "🛡", "🤫", "📜", "💳"]
        case .pvc:            return ["💾", "📀", "🗄", "📁", "🧮"]
        case .storageClass:   return ["🗃", "💿", "📚"]
        case .networkPolicy:  return ["🛡", "🚧", "🔒", "🧱"]
        case .serviceAccount: return ["👤", "🎫", "🛂", "🪪"]
        case .statefulSet:    return ["🗂", "🏛", "📚", "🧱"]
        case .replicaSet:     return ["♊️", "🧬", "🔁"]
        case .job:            return ["🔨", "⚒", "🛠", "🎯"]
        case .cronJob:        return ["⏰", "📆", "🔁", "⏳"]
        case .daemonSet:      return ["👹", "🛰", "📡"]
        case .configMap:      return ["📋", "📄", "⚙️", "🗒"]
        case .hpa:            return ["📈", "⚖️", "🎚", "📊"]
        case .event:          return ["🔔", "📣", "📢"]
        case .irsa:           return ["🪪", "🛂", "🗝", "☁️"]
        case .linkerd:        return ["🕸", "🔗", "🌊"]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Emoji for \(ref.kind.title) \(ref.key)")
                .font(.caption).foregroundStyle(.secondary)

            TextField("Type or paste emoji", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32)), count: 6), spacing: 6) {
                ForEach(presets, id: \.self) { e in
                    Button { emojis.set(e, for: ref); isOpen = false } label: {
                        Text(e).font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button("Open System Picker") {
                    NSApp.orderFrontCharacterPalette(nil)
                }
                .buttonStyle(.link)
                Spacer()
                Button("Cancel") { isOpen = false }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { text = emojis.emoji(for: ref) ?? "" }
    }

    private func save() {
        emojis.set(text, for: ref)
        isOpen = false
    }
}
