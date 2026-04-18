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

struct FilterBar<Trailing: View>: View {
    @Binding var text: String
    let placeholder: String
    let count: Int
    let trailing: Trailing

    init(text: Binding<String>, placeholder: String, count: Int,
         @ViewBuilder trailing: () -> Trailing) {
        self._text = text
        self.placeholder = placeholder
        self.count = count
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain)
            Spacer()
            trailing
            Text("\(count)").foregroundStyle(.secondary).font(.caption)
        }
        .padding(8)
        .background(.bar)
    }
}

extension FilterBar where Trailing == EmptyView {
    init(text: Binding<String>, placeholder: String, count: Int) {
        self.init(text: text, placeholder: placeholder, count: count) { EmptyView() }
    }
}
