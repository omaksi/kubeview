import SwiftUI

enum ViewMode: String, CaseIterable {
    case cards, table
    var icon: String {
        switch self {
        case .cards: return "square.grid.2x2"
        case .table: return "list.bullet"
        }
    }
}

struct ViewModeToggle: View {
    @Binding var mode: ViewMode
    var body: some View {
        Picker("View", selection: $mode) {
            ForEach(ViewMode.allCases, id: \.self) { m in
                Image(systemName: m.icon).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Toggle cards / table")
    }
}

/// Per-view header: count + optional trailing (usually the view-mode toggle).
/// The search field itself lives at the top of the window (`GlobalSearchBar`)
/// and drives every view through `SearchState`.
struct ViewHeader<Trailing: View>: View {
    let count: Int
    let label: String
    let trailing: Trailing

    init(count: Int, label: String = "items", @ViewBuilder trailing: () -> Trailing) {
        self.count = count
        self.label = label
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Spacer()
            trailing
            Text("\(count) \(label)").foregroundStyle(.secondary).font(.caption)
        }
        .padding(8)
        .background(.bar)
    }
}

/// 2pt indeterminate progress strip — a soft gradient sweep that loops while
/// `visible` is true and fades out otherwise. Meant to sit at the top of the
/// detail area; zero layout cost when hidden.
struct TopLoadingBar: View {
    let visible: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(LinearGradient(
                    colors: [.clear, Color.accentColor.opacity(0.9), .clear],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(width: geo.size.width * 0.4)
                .offset(x: phase * (geo.size.width * 1.4) - geo.size.width * 0.4)
        }
        .frame(height: 2)
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: visible)
        .onAppear {
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

