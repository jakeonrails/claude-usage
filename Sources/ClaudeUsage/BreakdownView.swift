import SwiftUI

/// "What ate my tokens?" — per-project/session usage breakdown for a
/// selectable timescale, backed by `BreakdownViewModel`. Hosted in its own
/// `NSWindow` by `BreakdownWindowController` (not the popover panel), since
/// it wants to be resizable and stick around across popover open/close.
struct BreakdownView: View {
    @ObservedObject var vm: BreakdownViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            timescalePicker
            Divider()
            body(for: vm.state)
            Divider()
            footer
        }
        .padding(16)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 460)
        .task { await vm.onAppear() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Usage breakdown")
                .font(.title3.bold())
            if let selected = vm.selected {
                Text(Self.rangeSubtitle(selected.range))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Timescale picker

    private var currentEntries: [WindowDescriptor] {
        vm.windows.filter { $0.kind == .currentFiveHour }
    }

    private var pastEntries: [WindowDescriptor] {
        vm.windows.filter { $0.kind == .pastFiveHour }
    }

    private var weeklyEntries: [WindowDescriptor] {
        vm.windows.filter {
            switch $0.kind {
            case .weekly, .weeklyScoped: return true
            case .currentFiveHour, .pastFiveHour: return false
            }
        }
    }

    private func pastTitle(_ d: WindowDescriptor) -> String {
        d.isExact ? d.title : "~\(d.title)"
    }

    private var timescalePicker: some View {
        Menu {
            ForEach(currentEntries) { d in
                Button(d.title) { Task { await vm.select(d) } }
            }
            if !pastEntries.isEmpty {
                Menu("Past 5h windows") {
                    ForEach(pastEntries) { d in
                        Button(pastTitle(d)) { Task { await vm.select(d) } }
                    }
                }
            }
            if !weeklyEntries.isEmpty {
                Divider()
                ForEach(weeklyEntries) { d in
                    Button(d.title) { Task { await vm.select(d) } }
                }
            }
        } label: {
            HStack {
                Text(vm.selected.map { $0.isExact ? $0.title : "~\($0.title)" } ?? "Select timescale")
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
        }
        .disabled(vm.windows.isEmpty)
        .fixedSize()
    }

    // MARK: Body

    @ViewBuilder
    private func body(for state: BreakdownViewModel.State) -> some View {
        switch state {
        case .idle:
            Spacer()
        case .loading:
            VStack {
                Spacer()
                ProgressView("Scanning local sessions…")
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .empty:
            VStack {
                Spacer()
                Text("No local Claude Code usage found for this window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .loaded(let result):
            resultBody(result)
        }
    }

    private func resultBody(_ result: BreakdownResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if result.projects.isEmpty {
                    Text("No local Claude Code usage found for this window.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    ForEach(result.projects) { project in
                        projectRow(project)
                    }
                }
                if let points = result.unattributedUtilizationPoints, points > 0 {
                    otherDevicesRow(points: points)
                }
            }
        }
    }

    // MARK: Rows

    private func projectRow(_ project: ProjectContribution) -> some View {
        let expanded = vm.expandedProjectIDs.contains(project.id)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                vm.toggleExpanded(project.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(project.displayName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        if let points = project.estimatedUtilizationPoints {
                            Text("≈ \(Self.pointsString(points)) pts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(Self.percentString(project.localSharePercent))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    UsageGauge(
                        utilization: project.localSharePercent,
                        timeElapsedFraction: nil,
                        fillColor: UsageColor.swiftUIColor(forUsed: project.localSharePercent)
                    )
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(project.sessions) { session in
                        sessionRow(session)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    private func sessionRow(_ session: SessionContribution) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(session.title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(Self.percentString(session.localSharePercent))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            UsageGauge(
                utilization: session.localSharePercent,
                timeElapsedFraction: nil,
                fillColor: UsageColor.swiftUIColor(forUsed: session.localSharePercent).opacity(0.7)
            )
        }
    }

    private func otherDevicesRow(points: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Other devices / claude.ai (est.)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("≈ \(Self.pointsString(points)) pts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            UsageGauge(
                utilization: points,
                timeElapsedFraction: nil,
                fillColor: Color.secondary.opacity(0.5)
            )
        }
        .padding(.top, 4)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Local Claude Code sessions on this Mac only. Weighted estimates — relative, not exact billing.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if case .loaded(let result) = vm.state, result.apiUtilization != nil {
                Text("Points estimate against Anthropic's reported utilization.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Formatting

    private static func percentString(_ pct: Double) -> String {
        "\(Int(pct.rounded()))%"
    }

    private static func pointsString(_ points: Double) -> String {
        String(format: "%.1f", points)
    }

    private static func rangeSubtitle(_ range: TimeWindow) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(formatter.string(from: range.start)) – \(formatter.string(from: range.end))"
    }
}
