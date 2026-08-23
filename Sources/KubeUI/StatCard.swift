import SwiftUI

public struct SectionHeader: View {
    let title: String
    let trailing: String?

    public init(title: String, trailing: String?) {
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let t = trailing {
                Text(t).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

public struct StatCard: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    public init(label: String, value: String, icon: String, color: Color) {
        self.label = label
        self.value = value
        self.icon = icon
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

public struct StatusBadge: View {
    let text: String
    let color: Color

    public init(text: String, color: Color) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

public struct UnhealthyItem: Hashable, Identifiable {
    public let kind: String
    public let namespace: String
    public let name: String
    public let reason: String
    public var id: String { "\(kind)/\(namespace)/\(name)" }

    public init(kind: String, namespace: String, name: String, reason: String) {
        self.kind = kind
        self.namespace = namespace
        self.name = name
        self.reason = reason
    }
}

public struct UnhealthyCard: View {
    let item: UnhealthyItem

    public init(item: UnhealthyItem) {
        self.item = item
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.kind).font(.caption2).foregroundStyle(.secondary)
                    Text(item.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Text(item.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Text(item.reason).font(.caption).foregroundStyle(color)
            }
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.4), lineWidth: 0.5)
        )
    }

    private var iconName: String {
        switch item.kind {
        case "Pod": return "shippingbox"
        case "Deployment": return "square.grid.2x2"
        case "StatefulSet": return "cylinder.split.1x2"
        case "ReplicaSet": return "rectangle.stack"
        case "Job": return "hammer"
        default: return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        // Crash/image backoff → red, rest → orange
        let critical: Set<String> = ["CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull",
                                      "Failed", "Error", "CreateContainerConfigError"]
        return critical.contains(item.reason) ? .red : .orange
    }
}

public enum PodCard {
    public static func phaseColor(_ phase: String) -> Color {
        switch phase {
        case "Running", "Succeeded": return .green
        case "Pending", "ContainerCreating": return .orange
        case "Failed", "Error", "CrashLoopBackOff": return .red
        default: return .secondary
        }
    }
}
