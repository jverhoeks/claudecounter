import SwiftUI
import ClaudeCounterCore

/// Two-Column Hybrid popover (layout B from the design):
/// hero numbers + chart on top → models | projects side-by-side →
/// live tail at the bottom → footer with refresh + ⚙.
///
/// The variable-height block in the middle (the two tables) is wrapped
/// in a ScrollView so a 12-project month doesn't push the hero / chart
/// off-screen. The footer stays pinned at the bottom outside the scroll.
struct PopoverView: View {
    @ObservedObject var state: AppState
    @State private var refreshing: Bool = false
    @State private var showSettings: Bool = false

    /// Cap each table at the top-N rows by USD. Anything beyond is
    /// reachable via the TUI / `claudecounter --once` — the menu bar
    /// is a glanceable surface, not the full ledger.
    private let topN = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Pinned-top: identity + chart. These are the "glance"
            // surface and must always be visible.
            HeroRow(state: state)
            HourlyChartRow(hourlyUSD: state.totals.todayHourlyUSD)

            // Scrollable middle: tables + live tail. Sized to fill
            // remaining vertical space.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 16) {
                        ByModelTable(month: state.totals.month, topN: topN)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ByProjectTable(month: state.totals.monthProj, topN: topN)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LiveTailSection(events: state.live)
                }
            }
            .frame(maxHeight: .infinity)

            // Pinned-bottom: refresh + settings.
            FooterRow(
                state: state,
                refreshing: $refreshing,
                showSettings: $showSettings
            )
        }
        .padding(14)
    }
}

// MARK: - Hero row

struct HeroRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                Text(formatUSD(todayUSD()))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("TODAY")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(formatUSD(monthUSD()))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("MONTH")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func todayUSD() -> Double {
        state.totals.day.values.reduce(0) { $0 + $1.usd }
    }
    private func monthUSD() -> Double {
        state.totals.month.values.reduce(0) { $0 + $1.usd }
    }
}

// MARK: - Hourly chart

struct HourlyChartRow: View {
    let hourlyUSD: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today's spend (per hour)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                let maxV = max(hourlyUSD.max() ?? 0, 0.0001)
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(hourlyUSD.enumerated()), id: \.offset) { idx, v in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor(forHour: idx, value: v))
                            .frame(height: max(3, CGFloat(v / maxV) * geo.size.height))
                    }
                }
            }
            .frame(height: 56)
        }
    }

    private func barColor(forHour hour: Int, value: Double) -> Color {
        let nowHour = Calendar.current.component(.hour, from: Date())
        if hour > nowHour { return Color.gray.opacity(0.20) }   // future hours dimmed
        if value <= 0 { return Color.gray.opacity(0.30) }
        return Color.green.opacity(0.85)
    }
}

// MARK: - By model

struct ByModelTable: View {
    let month: [String: ModelDay]
    var topN: Int = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("By model · month")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { name, usd, pct in
                HStack {
                    Text(shortModel(name)).foregroundStyle(.primary)
                    Spacer()
                    Text(formatUSDCompact(usd))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(formatPct(pct))
                        .frame(width: 38, alignment: .trailing)
                        .foregroundStyle(.green)
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
                .font(.system(size: 12))
            }
            if rows.isEmpty {
                Text("No spend yet this month")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if hiddenCount > 0 {
                Text("+ \(hiddenCount) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sortedRows: [(String, Double, Double)] {
        let total = month.values.reduce(0) { $0 + $1.usd }
        return month
            .map { (name: $0.key, usd: $0.value.usd) }
            .sorted { $0.usd > $1.usd }
            .map { ($0.name, $0.usd, total > 0 ? $0.usd / total : 0) }
    }

    private var rows: [(String, Double, Double)] { Array(sortedRows.prefix(topN)) }
    private var hiddenCount: Int { max(0, sortedRows.count - topN) }

    private func shortModel(_ name: String) -> String {
        // claude-opus-4-7 → opus-4-7 (drop "claude-" prefix for compactness)
        if name.hasPrefix("claude-") { return String(name.dropFirst("claude-".count)) }
        return name
    }
}

// MARK: - By project

struct ByProjectTable: View {
    let month: [String: ProjectDay]
    var topN: Int = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("By project · month (M / sub)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { name, total, main, sub in
                HStack {
                    Text(shortProject(name))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(formatUSDCompact(total))
                            .monospacedDigit()
                        Text("M \(formatUSDCompact(main)) · sub \(formatUSDCompact(sub))")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 12))
            }
            if rows.isEmpty {
                Text("No projects yet this month")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if hiddenCount > 0 {
                Text("+ \(hiddenCount) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sortedRows: [(String, Double, Double, Double)] {
        month
            .map { (name: $0.key, total: $0.value.totalUSD, main: $0.value.mainUSD, sub: $0.value.subUSD) }
            .sorted { $0.total > $1.total }
            .map { ($0.name, $0.total, $0.main, $0.sub) }
    }

    private var rows: [(String, Double, Double, Double)] { Array(sortedRows.prefix(topN)) }
    private var hiddenCount: Int { max(0, sortedRows.count - topN) }

    private func shortProject(_ encoded: String) -> String {
        // Drop the leading parts that come from /Users/<u>/.... and show
        // the tail. Mirrors the Go TUI's shortProject helper.
        if encoded.isEmpty { return "(unknown)" }
        let trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        let parts = trimmed.split(separator: "-")
        if parts.count <= 4 { return trimmed }
        return parts.dropFirst(4).joined(separator: "-")
    }
}

// MARK: - Live tail

struct LiveTailSection: View {
    let events: [LiveEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Live")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(events.prefix(8)) { ev in
                        LiveTailRow(event: ev)
                    }
                    if events.isEmpty {
                        Text("Waiting for activity…")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 100)
        }
    }
}

struct LiveTailRow: View {
    let event: LiveEvent

    var body: some View {
        HStack(spacing: 8) {
            Text(formatTime(event.timestamp))
                .foregroundStyle(.secondary)
            Text(shortName(event.project))
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(shortModel(event.model))
                .frame(width: 56, alignment: .leading)
                .foregroundStyle(.secondary)
            Text("+\(formatUSDFine(event.usd))")
                .foregroundStyle(.green)
                .monospacedDigit()
            if event.isSubagent {
                Text("(sub)")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
            }
            Spacer()
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func shortName(_ encoded: String) -> String {
        if encoded.isEmpty { return "(?)" }
        let trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        let parts = trimmed.split(separator: "-")
        if parts.count <= 4 { return trimmed }
        return parts.dropFirst(4).joined(separator: "-")
    }

    private func shortModel(_ id: String) -> String {
        if id.contains("opus")   { return "opus" }
        if id.contains("sonnet") { return "sonnet" }
        if id.contains("haiku")  { return "haiku" }
        return id
    }
}

// MARK: - Footer

struct FooterRow: View {
    @ObservedObject var state: AppState
    @Binding var refreshing: Bool
    @Binding var showSettings: Bool

    var body: some View {
        HStack {
            statusText
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task {
                    refreshing = true
                    await state.refresh()
                    refreshing = false
                }
            } label: {
                Label(refreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(refreshing)

            Menu {
                Button("Refresh pricing from LiteLLM") {
                    Task {
                        do {
                            let table = try await PricingFetcher.fetch()
                            try table.writeToAppOverride()
                            await state.updatePricing(table)
                        } catch {
                            // Surface via lastError; Menu doesn't have an
                            // alert affordance from here.
                        }
                    }
                }
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gear")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch state.status {
        case .starting:                  Text("Starting…")
        case .scanning:                  Text("Scanning…")
        case .live:                      Text("Updated \(timeSince(state.totals.asOf))")
        case .noProjectsRoot(let path):  Text("No data at \(path)").foregroundStyle(.red)
        }
    }

    private func timeSince(_ d: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(d)))
        if secs < 60 { return "\(secs)s ago" }
        let mins = secs / 60
        return "\(mins)m ago"
    }
}

// MARK: - Currency formatters

func formatUSD(_ usd: Double) -> String {
    if usd >= 1000 {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: usd)) ?? String(format: "$%.2f", usd)
    }
    return String(format: "$%.2f", usd)
}

func formatUSDFine(_ usd: Double) -> String {
    if usd >= 1 { return String(format: "$%.2f", usd) }
    return String(format: "$%.3f", usd)
}

func formatPct(_ pct: Double) -> String {
    if pct >= 0.10 { return String(format: "%.0f%%", pct * 100) }
    return String(format: "%.1f%%", pct * 100)
}

private func formatTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: d)
}
