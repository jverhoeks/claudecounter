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
            // Pinned-top: identity + charts. These are the "glance"
            // surface and must always be visible.
            HeroRow(state: state)
            HourlyChartRow(hourlyUSD: state.totals.todayHourlyUSD)
            MonthlyChartRow(daily: state.totals.daily)

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
    @State private var hoveredHour: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Today's spend (per hour)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // Inline readout for the hovered hour. Lives in the
                // section header so it doesn't reflow the chart.
                if let h = hoveredHour, h < hourlyUSD.count {
                    HStack(spacing: 4) {
                        Text(formatHour(h))
                            .foregroundStyle(.primary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(formatUSDFine(hourlyUSD[h]))
                            .foregroundStyle(hourlyUSD[h] > 0 ? .green : .secondary)
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .frame(height: 12)

            GeometryReader { geo in
                let maxV = max(hourlyUSD.max() ?? 0, 0.0001)
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(hourlyUSD.enumerated()), id: \.offset) { idx, v in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor(forHour: idx, value: v, hovered: idx == hoveredHour))
                            .frame(height: max(3, CGFloat(v / maxV) * geo.size.height))
                    }
                }
                // Continuous hover tracking over the chart area.
                // We map mouse-x → bar index by dividing by the per-bar
                // slot width (bar width + spacing). `.ended` clears the
                // selection so the readout disappears when the mouse
                // leaves the chart.
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoveredHour = hourIndex(for: point.x,
                                                width: geo.size.width,
                                                count: hourlyUSD.count)
                    case .ended:
                        hoveredHour = nil
                    }
                }
            }
            .frame(height: 56)
        }
        .animation(.easeInOut(duration: 0.12), value: hoveredHour)
    }

    /// Map an x-coordinate inside the chart to one of the 24 hour
    /// buckets. Even spacing → integer division by per-bar slot width.
    private func hourIndex(for x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0, x >= 0, x <= width else { return nil }
        let slot = width / CGFloat(count)
        let idx = Int((x / slot).rounded(.down))
        return min(max(idx, 0), count - 1)
    }

    private func barColor(forHour hour: Int, value: Double, hovered: Bool) -> Color {
        // Hovered bar is always vivid, even for past zero or future hours,
        // so the readout makes visual sense as the user scrubs across.
        if hovered { return Color.green }
        let nowHour = Calendar.current.component(.hour, from: Date())
        if hour > nowHour { return Color.gray.opacity(0.20) }   // future hours dimmed
        if value <= 0 { return Color.gray.opacity(0.30) }
        return Color.green.opacity(0.85)
    }

    private func formatHour(_ h: Int) -> String {
        String(format: "%02d:00", h)
    }
}

// MARK: - Monthly chart (last 30 days)

/// One bar per day for the last 30 days, oldest → newest. Same hover
/// idiom as `HourlyChartRow`: pointer over a bar highlights it and
/// shows `YYYY-MM-DD · $X.XX` in the section header.
struct MonthlyChartRow: View {
    let daily: [DailyTotal]
    @State private var hoveredIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Last 30 days")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let i = hoveredIndex, i < daily.count {
                    HStack(spacing: 4) {
                        Text(formatDay(daily[i].day))
                            .foregroundStyle(.primary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(formatUSDFine(daily[i].usd))
                            .foregroundStyle(daily[i].usd > 0 ? .green : .secondary)
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                } else {
                    // Static summary when no bar is hovered: range of
                    // days + total spend across the window. Gives the
                    // user something useful to read in the header.
                    Text(summary)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(height: 12)

            GeometryReader { geo in
                let maxV = max(daily.map { $0.usd }.max() ?? 0, 0.0001)
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(Array(daily.enumerated()), id: \.offset) { idx, entry in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(barColor(idx: idx, value: entry.usd, isToday: idx == daily.count - 1))
                            .frame(height: max(2, CGFloat(entry.usd / maxV) * geo.size.height))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoveredIndex = barIndex(for: point.x,
                                                width: geo.size.width,
                                                count: daily.count)
                    case .ended:
                        hoveredIndex = nil
                    }
                }
            }
            .frame(height: 56)
        }
        .animation(.easeInOut(duration: 0.12), value: hoveredIndex)
    }

    private func barIndex(for x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0, x >= 0, x <= width else { return nil }
        let slot = width / CGFloat(count)
        let idx = Int((x / slot).rounded(.down))
        return min(max(idx, 0), count - 1)
    }

    /// Bars are color-graded by index in the window:
    /// - Today's bar (last entry): solid bright green, the "you are here"
    ///   anchor, even when zero-spend.
    /// - Hovered bar: solid green to make scrubbing obvious.
    /// - Zero-spend bars: muted gray track.
    /// - Everything else: green at 0.85 alpha.
    private func barColor(idx: Int, value: Double, isToday: Bool) -> Color {
        if hoveredIndex == idx { return Color.green }
        if isToday { return Color.green.opacity(0.95) }
        if value <= 0 { return Color.gray.opacity(0.30) }
        return Color.green.opacity(0.75)
    }

    private var summary: String {
        let total = daily.reduce(0) { $0 + $1.usd }
        guard let first = daily.first?.day, let last = daily.last?.day else {
            return "no data"
        }
        return "\(formatDay(first))…\(formatDay(last)) · \(formatUSDCompact(total))"
    }

    /// "2026-04-26" → "Apr 26"
    private func formatDay(_ ymd: String) -> String {
        let inFmt = DateFormatter()
        inFmt.dateFormat = "yyyy-MM-dd"
        guard let d = inFmt.date(from: ymd) else { return ymd }
        let outFmt = DateFormatter()
        outFmt.dateFormat = "MMM d"
        outFmt.locale = Locale(identifier: "en_US_POSIX")
        return outFmt.string(from: d)
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

    /// Local mirror of the SMAppService state so the toggle can read it
    /// synchronously. Refreshed every time the menu opens (cheap call,
    /// no syscalls — just reads launchd state).
    @State private var launchAtLogin: LaunchAtLoginState = .disabled
    private let launchService: LaunchAtLoginService = SMAppServiceLaunchAtLogin()

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
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin == .enabled },
                    set: { newValue in toggleLaunchAtLogin(to: newValue) }
                ))
                if launchAtLogin == .requiresApproval {
                    Text("Open System Settings → General → Login Items to approve.")
                }
                Toggle("Show dock icon with spend", isOn: Binding(
                    get: { state.settings.dockIconEnabled },
                    set: { newValue in state.setDockIconEnabled(newValue) }
                ))
                Divider()
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
            .onAppear { launchAtLogin = launchService.currentState() }
        }
    }

    /// Toggle launch-at-login. macOS may pop a one-time approval prompt
    /// on first enable; if the user dismisses it the state stays
    /// `.requiresApproval` and we surface a hint underneath the toggle.
    private func toggleLaunchAtLogin(to enabled: Bool) {
        do {
            try launchService.setEnabled(enabled)
        } catch {
            // Don't crash on launchd quirks; just leave the toggle
            // reflecting the actual current state.
        }
        launchAtLogin = launchService.currentState()
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
