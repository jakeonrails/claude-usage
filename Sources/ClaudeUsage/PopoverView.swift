import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @State private var now: Date = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            sessionSection

            Divider()

            weeklySection

            if let opus = store.sevenDayOpus, opus.utilization != nil {
                modelRow(label: "Weekly Opus", window: opus)
            }
            if let sonnet = store.sevenDaySonnet, sonnet.utilization != nil {
                modelRow(label: "Weekly Sonnet", window: sonnet)
            }

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .onReceive(tick) { now = $0 }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text("Claude Code Usage")
                .font(.headline)
            Spacer()
            if case .loading = store.state {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("5-hour session").font(.subheadline).foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline) {
                Text(UsageFormat.percentString(store.fiveHour?.utilization))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("used")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let resetDate = UsageFormat.parseResetsAt(store.fiveHour?.resets_at) {
                    Text("Resets in \(UsageFormat.compactDuration(until: resetDate, now: now))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if let util = store.fiveHour?.utilization {
                ProgressView(value: min(max(util, 0), 100), total: 100)
                    .tint(fiveHourColor)
            }
        }
    }

    private var weeklySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Weekly").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(UsageFormat.percentString(store.sevenDay?.utilization))
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text("used")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let resetDate = UsageFormat.parseResetsAt(store.sevenDay?.resets_at) {
                    Text("Resets in \(UsageFormat.coarseDuration(until: resetDate, now: now))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let util = store.sevenDay?.utilization {
                ProgressView(value: min(max(util, 0), 100), total: 100)
            }
        }
    }

    private func modelRow(label: String, window: UsageWindow) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(UsageFormat.percentString(window.utilization))
                .font(.caption)
                .monospacedDigit()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = store.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            HStack {
                if let last = store.lastUpdated {
                    Text("Updated \(last.formatted(.dateTime.hour().minute().second()))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await store.refresh() } }
                    .controlSize(.small)
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }

    // MARK: Derived

    private var fiveHourColor: Color {
        guard let util = store.fiveHour?.utilization else { return .secondary }
        return UsageColor.swiftUIColor(forUsed: util)
    }
}
