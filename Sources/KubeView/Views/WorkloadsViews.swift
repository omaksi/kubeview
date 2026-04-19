import SwiftUI

// MARK: - Deployments

struct DeploymentsView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState
    @State private var mode: ViewMode = .cards
    @State private var unhealthyOnly = false

    var filtered: [Deployment] {
        let base = unhealthyOnly ? store.deployments.filter { !$0.isHealthy } : store.deployments
        return base.searchFiltered(search) { [$0.name, $0.namespace] }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(count: filtered.count, label: "deployments") {
                HStack(spacing: 8) {
                    Toggle("Unhealthy only", isOn: $unhealthyOnly)
                        .toggleStyle(.switch).controlSize(.small)
                    ViewModeToggle(mode: $mode)
                }
            }
            switch mode {
            case .cards: cards
            case .table: table
            }
        }
    }

    private var cards: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
                ForEach(filtered) { d in
                    let ref = ResourceRef(kind: .deployment, key: d.id)
                    ResourceCard(ref: ref) {
                        WorkloadCardBody(
                            ref: ref,
                            name: d.name, namespace: d.namespace,
                            desired: d.desired, ready: d.ready,
                            kindLabel: "Deployment", strategy: d.strategy,
                            healthy: d.isHealthy, reason: d.unhealthyReason, age: d.age
                        )
                    }
                }
            }.padding(12)
        }
    }

    private var table: some View {
        Table(filtered) {
            TableColumn("Namespace") { Text($0.namespace).font(.system(.body, design: .monospaced)) }
            TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
            TableColumn("Ready") { d in
                Text("\(d.ready)/\(d.desired)").foregroundStyle(d.isHealthy ? Color.primary : Color.orange)
            }.width(min: 60, ideal: 80)
            TableColumn("Up-to-date") { Text("\($0.updated)") }.width(min: 60, ideal: 80)
            TableColumn("Available") { Text("\($0.available)") }.width(min: 60, ideal: 80)
            TableColumn("Strategy") { Text($0.strategy).foregroundStyle(.secondary) }
            TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
        }
    }
}

// MARK: - StatefulSets

struct StatefulSetsView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState
    @State private var mode: ViewMode = .cards

    var filtered: [StatefulSet] {
        store.statefulSets.searchFiltered(search) { [$0.name, $0.namespace] }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(count: filtered.count, label: "statefulsets") { ViewModeToggle(mode: $mode) }
            switch mode {
            case .cards:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { ss in
                            let ref = ResourceRef(kind: .statefulSet, key: ss.id)
                            ResourceCard(ref: ref) {
                                WorkloadCardBody(
                                    ref: ref,
                                    name: ss.name, namespace: ss.namespace,
                                    desired: ss.desired, ready: ss.ready,
                                    kindLabel: "StatefulSet", strategy: ss.serviceName,
                                    healthy: ss.isHealthy, reason: ss.unhealthyReason, age: ss.age
                                )
                            }
                        }
                    }.padding(12)
                }
            case .table:
                Table(filtered) {
                    TableColumn("Namespace") { Text($0.namespace).font(.system(.body, design: .monospaced)) }
                    TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                    TableColumn("Ready") { s in
                        Text("\(s.ready)/\(s.desired)").foregroundStyle(s.isHealthy ? Color.primary : Color.orange)
                    }.width(min: 60, ideal: 80)
                    TableColumn("Service") { Text($0.serviceName).foregroundStyle(.secondary) }
                    TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
                }
            }
        }
    }
}

// MARK: - ReplicaSets

struct ReplicaSetsView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState
    @State private var mode: ViewMode = .cards
    @State private var hideScaledToZero = true

    var filtered: [ReplicaSet] {
        let base = hideScaledToZero ? store.replicaSets.filter { $0.desired > 0 } : store.replicaSets
        return base.searchFiltered(search) { [$0.name, $0.namespace] }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(count: filtered.count, label: "replicasets") {
                HStack(spacing: 8) {
                    Toggle("Hide scaled-to-0", isOn: $hideScaledToZero)
                        .toggleStyle(.switch).controlSize(.small)
                    ViewModeToggle(mode: $mode)
                }
            }
            switch mode {
            case .cards:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { rs in
                            let ref = ResourceRef(kind: .replicaSet, key: rs.id)
                            ResourceCard(ref: ref) {
                                WorkloadCardBody(
                                    ref: ref,
                                    name: rs.name, namespace: rs.namespace,
                                    desired: rs.desired, ready: rs.ready,
                                    kindLabel: "ReplicaSet", strategy: nil,
                                    healthy: rs.isHealthy, reason: rs.unhealthyReason, age: rs.age
                                )
                            }
                        }
                    }.padding(12)
                }
            case .table:
                Table(filtered) {
                    TableColumn("Namespace") { Text($0.namespace).font(.system(.body, design: .monospaced)) }
                    TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                    TableColumn("Ready") { r in
                        Text("\(r.ready)/\(r.desired)").foregroundStyle(r.isHealthy ? Color.primary : Color.orange)
                    }.width(min: 60, ideal: 80)
                    TableColumn("Available") { Text("\($0.available)") }.width(min: 60, ideal: 80)
                    TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
                }
            }
        }
    }
}

// MARK: - Jobs

struct JobsView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState
    @State private var mode: ViewMode = .cards

    var filtered: [KubeJob] {
        store.jobs.searchFiltered(search) { [$0.name, $0.namespace] }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(count: filtered.count, label: "jobs") { ViewModeToggle(mode: $mode) }
            switch mode {
            case .cards:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { job in
                            ResourceCard(ref: .init(kind: .job, key: job.id)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        ResourceTitle(ref: .init(kind: .job, key: job.id), name: job.name)
                                        Spacer()
                                        StatusBadge(text: job.phase, color: jobPhaseColor(job.phase))
                                    }
                                    Text(job.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    HStack(spacing: 12) {
                                        mini("Completions", "\(job.succeeded)/\(job.completions)")
                                        mini("Active", "\(job.active)")
                                        mini("Failed", "\(job.failed)",
                                             tint: job.failed > 0 ? .red : nil)
                                    }
                                    HStack(spacing: 12) {
                                        mini("Duration", job.duration)
                                        mini("Age", job.age)
                                    }
                                }
                            }
                        }
                    }.padding(12)
                }
            case .table:
                Table(filtered) {
                    TableColumn("Namespace") { Text($0.namespace).font(.system(.body, design: .monospaced)) }
                    TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                    TableColumn("Status") { j in Text(j.phase).foregroundStyle(jobPhaseColor(j.phase)) }
                    TableColumn("Completions") { Text("\($0.succeeded)/\($0.completions)") }
                    TableColumn("Active") { Text("\($0.active)") }.width(min: 50, ideal: 70)
                    TableColumn("Failed") { j in Text("\(j.failed)").foregroundStyle(j.failed > 0 ? .red : .secondary) }
                    TableColumn("Duration") { Text($0.duration) }
                    TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
                }
            }
        }
    }
}

// MARK: - CronJobs

struct CronJobsView: View {
    @EnvironmentObject var store: ClusterStore
    @EnvironmentObject var search: SearchState
    @State private var mode: ViewMode = .cards

    var filtered: [CronJob] {
        store.cronJobs.searchFiltered(search) { [$0.name, $0.namespace] }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(count: filtered.count, label: "cronjobs") { ViewModeToggle(mode: $mode) }
            switch mode {
            case .cards:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { cj in
                            ResourceCard(ref: .init(kind: .cronJob, key: cj.id)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        ResourceTitle(ref: .init(kind: .cronJob, key: cj.id), name: cj.name)
                                        Spacer()
                                        if cj.suspend {
                                            StatusBadge(text: "Suspended", color: .orange)
                                        }
                                    }
                                    Text(cj.namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    HStack(spacing: 6) {
                                        Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
                                        Text(cj.schedule).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                    HStack(spacing: 12) {
                                        mini("Active", "\(cj.activeCount)")
                                        mini("Last OK", cj.lastRunAge ?? "-")
                                        mini("Age", cj.age)
                                    }
                                }
                            }
                        }
                    }.padding(12)
                }
            case .table:
                Table(filtered) {
                    TableColumn("Namespace") { Text($0.namespace).font(.system(.body, design: .monospaced)) }
                    TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                    TableColumn("Schedule") { Text($0.schedule).font(.caption.monospaced()) }
                    TableColumn("Suspend") { cj in Text(cj.suspend ? "yes" : "no") }.width(min: 60, ideal: 80)
                    TableColumn("Active") { Text("\($0.activeCount)") }.width(min: 50, ideal: 70)
                    TableColumn("Last OK") { Text($0.lastRunAge ?? "-") }
                    TableColumn("Age") { Text($0.age) }.width(min: 40, ideal: 60)
                }
            }
        }
    }
}

// MARK: - Shared helpers

struct WorkloadCardBody: View {
    let ref: ResourceRef
    let name: String
    let namespace: String
    let desired: Int
    let ready: Int
    let kindLabel: String
    let strategy: String?
    let healthy: Bool
    let reason: String?
    let age: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ResourceTitle(ref: ref, name: name)
                Spacer()
                StatusBadge(text: "\(ready)/\(desired)", color: healthy ? .green : .orange)
            }
            Text(namespace).font(.caption2.monospaced()).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Kind").font(.caption2).foregroundStyle(.secondary)
                    Text(kindLabel).font(.caption.monospaced())
                }
                if let strategy {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Strategy").font(.caption2).foregroundStyle(.secondary)
                        Text(strategy).font(.caption.monospaced())
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Age").font(.caption2).foregroundStyle(.secondary)
                    Text(age).font(.caption.monospacedDigit())
                }
            }
            if !healthy, let r = reason {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                    Text(r).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

private func mini(_ label: String, _ value: String, tint: Color? = nil) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(label).font(.caption2).foregroundStyle(.secondary)
        Text(value).font(.caption.monospacedDigit()).foregroundStyle(tint ?? .primary)
    }
}

private func jobPhaseColor(_ p: String) -> Color {
    switch p {
    case "Complete": return .green
    case "Failed": return .red
    case "Running": return .blue
    default: return .secondary
    }
}
