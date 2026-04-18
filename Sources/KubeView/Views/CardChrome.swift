import SwiftUI

/// Wraps a card body with subtle left accent stripe (resource kind) and an
/// optional namespace-based background tint. Adds context menu for emoji assignment.
struct ResourceCard<Content: View>: View {
    let ref: ResourceRef
    let namespaceForTint: String?
    @EnvironmentObject var emojis: EmojiStore
    @State private var pickerOpen = false
    let content: Content

    init(ref: ResourceRef,
         namespaceForTint: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.ref = ref
        self.namespaceForTint = namespaceForTint
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let e = emojis.emoji(for: ref) {
                    Text(e)
                        .font(.system(size: 18))
                        .padding(6)
                }
            }
        }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(ref.kind.accent.opacity(0.18), lineWidth: 0.5)
        )
        .contextMenu {
            Button("Set Emoji…") { pickerOpen = true }
            if emojis.emoji(for: ref) != nil {
                Button("Clear Emoji", role: .destructive) { emojis.set(nil, for: ref) }
            }
        }
        .popover(isPresented: $pickerOpen, arrowEdge: .top) {
            EmojiPicker(ref: ref, isOpen: $pickerOpen).environmentObject(emojis)
        }
    }

    private var background: some View {
        let nsTint = namespaceForTint.map { NamespacePalette.color(for: $0) }
        return ZStack {
            Color.clear.background(.quaternary.opacity(0.4))
            (nsTint ?? ref.kind.accent).opacity(0.05)
        }
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
        case .namespace: return ["📦", "🏷", "🧩", "🧪", "🚀", "🔒", "💼", "🌐", "🧰", "🛠", "💾", "📡"]
        case .pod:       return ["🐳", "🧊", "🔧", "⚙️", "🚦", "🔥", "💤", "🎯"]
        case .node:      return ["🖥", "🧱", "🗄", "⚡️", "🌡", "💪"]
        case .service:   return ["🔌", "🧵", "🔁", "🧭", "📮", "🛰"]
        case .ingress:   return ["🌐", "🔐", "🚪", "📥", "🧱", "🛣"]
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
