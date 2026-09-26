import SwiftUI
import AppKit
import Charts
import ClaudeCounterCore

/// Owns the one dashboard window. Plain AppKit rather than a SwiftUI
/// `Window` scene: in a MenuBarExtra app that scene is created hidden
/// at launch and pops up whenever the app activates, i.e. on every
/// click of the menu-bar icon.
@MainActor
enum DashboardWindow {
    private static var window: NSWindow?

    static func show(state: AppState) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: DashboardView(state: state)))
            w.title = "ClaudeCounter Dashboard"
            w.setContentSize(NSSize(width: 900, height: 880))
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("ClaudeCounterDashboard")
            window = w
        }
        // LSUIElement app: without this the window opens behind others.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Standalone analytics window: daily trend per series, efficiency
/// stats, and what each subscription is worth against its fee. Every
/// figure is derived from `Totals`, so it tracks the popover live.
struct DashboardView: View {
    @ObservedObject var state: AppState

    @State private var rangeDays = 30
    @State private var mode: Analytics.Dimension = .model
    @State private var showTokens = false
    /// Row clicked in the table: scopes the KPIs (and, in model view,
    /// the heatmap) to that series and highlights its line.
    @State private var selected: String?
    /// Table sort: clicking a header sorts by it, clicking again flips.
    @State private var sortColumn: Column = .spend
    @State private var sortAscending = false

    private enum Column: String, CaseIterable {
        case name, spend, share, tokens, tokensPerUSD, output, cacheHit
        var title: String {
            switch self {
            case .name: return ""
            case .spend: return "Spend"
            case .share: return "Share"
            case .tokens: return "Tokens"
            case .tokensPerUSD: return "Tokens / $"
            case .output: return "Output"
            case .cacheHit: return "Cache hit"
            }
        }
        /// Share is spend over a shared total, so it sorts as spend.
        func key(_ name: String, _ v: ModelDay) -> Double {
            switch self {
            case .name: return 0
            case .spend, .share: return v.usd
            case .tokens: return Double(v.tokens.total)
            case .tokensPerUSD: return v.tokensPerUSD ?? -1
            case .output: return Double(v.tokens.output)
            case .cacheHit: return v.tokens.cacheHitRate
            }
        }
    }

    private var days: [String] { Analytics.days(ending: state.totals.asOf, count: rangeDays) }

    var body: some View {
        let days = self.days
        let grouped = Analytics.grouped(state.totals, by: mode)
        let series = Analytics.series(grouped, days: days)
        let rows = Analytics.sum(grouped, days: days).sorted { $0.value.usd > $1.value.usd }
        let coverage = Analytics.coverage(state.totals, days: days, by: mode)
        // Stale after a range/mode change that drops the row.
        let focus = rows.contains { $0.key == selected } ? selected : nil
        let monthDays = Analytics.days(ending: state.totals.asOf,
                                       count: Calendar.current.component(.day, from: state.totals.asOf))
        let month = Analytics.sum(grouped, days: monthDays)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controls
                kpis(rows.filter { focus == nil || $0.key == focus }.map(\.value),
                     monthUSD: month.filter { focus == nil || $0.key == focus }.values.reduce(0) { $0 + $1.usd },
                     days: days.count, title: focus)
                chart(series, days: days, focus: focus)
                if let first = state.totals.history.keys.min(), first > days[0] {
                    Text("History starts \(first): the app keeps what it has scanned since it was installed, and scans only ~35 days back on a fresh start.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GroupBox("By \(mode.rawValue) · last \(rangeDays) days · click a row to focus it, a header to sort") { seriesTable(rows, coverage: coverage, focus: focus) }
                GroupBox("When you spend · last 30 days, weekday × hour" + (mode == .model && focus != nil ? " · \(focus!)" : "")) {
                    heatmap(model: mode == .model ? focus : nil)
                }
                GroupBox("Subscriptions · API-equivalent spend vs fee") { subscriptions }
            }
            .padding(16)
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    // MARK: Controls

    private var controls: some View {
        HStack {
            Picker("Range", selection: $rangeDays) {
                Text("7d").tag(7); Text("30d").tag(30); Text("90d").tag(90); Text("1y").tag(365)
            }
            .pickerStyle(.segmented).frame(width: 220)
            Picker("Group", selection: $mode) {
                ForEach(Analytics.Dimension.allCases, id: \.self) {
                    Text($0 == .agent ? "Main/sub" : $0.rawValue.capitalized).tag($0)
                }
            }
            .pickerStyle(.segmented).frame(width: 420)
            .onChange(of: mode) { _ in selected = nil }
            Picker("", selection: $showTokens) {
                Text("$").tag(false); Text("Tokens").tag(true)
            }
            .pickerStyle(.segmented).frame(width: 120)
        }
        .labelsHidden()
    }

    // MARK: KPIs

    private func kpis(_ values: [ModelDay], monthUSD: Double, days: Int, title: String?) -> some View {
        let usd = values.reduce(0) { $0 + $1.usd }
        let tokens = values.reduce(TokenCounts.zero) { $0.adding($1.tokens) }
        return VStack(alignment: .leading, spacing: 4) {
            if let title {
                HStack {
                    Text(title).font(.headline)
                    Button("Show all") { selected = nil }.buttonStyle(.link)
                }
            }
            HStack(spacing: 10) {
            tile("Spend", usdString(usd))
            tile("Tokens", tokenString(Double(tokens.total)))
            tile("Tokens / $", usd > 0 ? tokenString(Double(tokens.total) / usd) : "—")
            tile("Avg / day", usdString(usd / Double(max(days, 1))))
            tile("Cache hit", percent(tokens.cacheHitRate))
            tile("Month projected",
                 usdString(Analytics.projectedMonth(monthToDate: monthUSD, now: state.totals.asOf)))
            }
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Chart

    private struct Point: Identifiable {
        let series: String; let date: Date; let value: Double
        var id: String { series + "\(date.timeIntervalSince1970)" }
    }

    private func chart(_ series: [(name: String, values: [ModelDay])], days: [String],
                       focus: String?) -> some View {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dates = days.map { fmt.date(from: $0) ?? .distantPast }
        let points = series.flatMap { name, values in
            values.enumerated().map { i, v in
                Point(series: name, date: dates[i],
                      value: showTokens ? Double(v.tokens.total) : v.usd)
            }
        }
        return Chart(points) {
            LineMark(x: .value("Day", $0.date, unit: .day),
                     y: .value(showTokens ? "Tokens" : "USD", $0.value))
                .foregroundStyle(by: .value("Series", $0.series))
                .interpolationMethod(.monotone)
                .opacity(focus == nil || $0.series == focus ? 1 : 0.15)
                .lineStyle(StrokeStyle(lineWidth: $0.series == focus ? 3 : 1.5))
        }
        // Explicit so "other" is grey rather than a reused series hue.
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.enumerated().map { i, s in
            s.name == "other" ? Color.gray : ModelPalette.colours[i % ModelPalette.colours.count]
        })
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(showTokens ? tokenString(d) : usdString(d)) }
                }
            }
        }
        .frame(height: 260)
    }

    // MARK: Per-series table

    private func seriesTable(_ rows: [(key: String, value: ModelDay)],
                             coverage: [String: Coverage], focus: String?) -> some View {
        let totalUSD = rows.reduce(0) { $0 + $1.value.usd }
        let rows = rows.sorted { a, b in
            let (x, y) = sortAscending ? (a, b) : (b, a)
            if sortColumn == .name { return x.key < y.key }
            let kx = sortColumn.key(x.key, x.value), ky = sortColumn.key(y.key, y.value)
            return kx == ky ? a.key < b.key : kx < ky
        }
        return Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                ForEach(Column.allCases, id: \.self) { c in
                    header(c == .name ? mode.rawValue.capitalized : c.title, c)
                        .gridColumnAlignment(c == .name ? .leading : .trailing)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(rows, id: \.key) { name, v in
                GridRow {
                    Text(name).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 4) {
                        Text(usdString(v.usd))
                        // A floor, not a total: some of this model's turns
                        // carried no usage. Same marker as the popover.
                        if let c = coverage[name], c.partial {
                            Text("~\(Int((c.fraction * 100).rounded()))%")
                                .font(.caption2).foregroundStyle(.secondary)
                                .help("Only this share of turns reported usage; spend is a lower bound.")
                        }
                    }
                    Text(totalUSD > 0 ? percent(v.usd / totalUSD) : "—")
                    Text(tokenString(Double(v.tokens.total)))
                    Text(v.tokensPerUSD.map(tokenString) ?? "—")
                    Text(tokenString(Double(v.tokens.output)))
                    Text(percent(v.tokens.cacheHitRate))
                }
                .monospacedDigit()
                .fontWeight(name == focus ? .semibold : nil)
                .foregroundStyle(focus == nil || name == focus ? .primary : .secondary)
                .contentShape(Rectangle())
                .onTapGesture { selected = (selected == name ? nil : name) }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ title: String, _ c: Column) -> some View {
        Button {
            if sortColumn == c { sortAscending.toggle() }
            else { sortColumn = c; sortAscending = (c == .name) }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if sortColumn == c {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(sortColumn == c ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Heatmap

    private struct Cell: Identifiable {
        let row: Int; let hour: Int; let usd: Double
        var id: Int { row * 24 + hour }
    }

    private func heatmap(model: String?) -> some View {
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let grid = Analytics.heatmap(state.totals.daily, model: model)
        // Row 6 = Monday: the y axis grows upward and Monday reads first.
        let cells = grid.enumerated().flatMap { wd, hours in
            hours.enumerated().map { Cell(row: 6 - wd, hour: $0, usd: $1) }
        }
        // Colour tops out at the 90th percentile of active hours, so one
        // outlier hour doesn't leave everything else cold blue.
        let active = cells.map(\.usd).filter { $0 > 0 }.sorted()
        let cap = max(active.isEmpty ? 1 : active[Int(Double(active.count - 1) * 0.9)], 0.01)
        // Explicit cell edges: category axes rendered these as thin strips.
        return Chart(cells) {
            RectangleMark(xStart: .value("Hour", Double($0.hour) + 0.05),
                          xEnd: .value("Hour", Double($0.hour) + 0.95),
                          yStart: .value("Day", Double($0.row) + 0.06),
                          yEnd: .value("Day", Double($0.row) + 0.94))
                .foregroundStyle(by: .value("Spend", min($0.usd, cap)))
                .cornerRadius(3)
        }
        // Classic heat ramp, cold → hot; idle hours stay near-background.
        .chartForegroundStyleScale(domain: 0...cap,
                                   range: Gradient(colors: [.gray.opacity(0.12), .blue, .cyan, .yellow, .orange, .red]))
        .chartXScale(domain: 0...24)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0.5, to: 24, by: 3))) { v in
                AxisValueLabel { Text(String(format: "%02d", Int(v.as(Double.self) ?? 0))) }
            }
        }
        .chartYScale(domain: 0...7)
        .chartYAxis {
            AxisMarks(position: .leading, values: (0..<7).map { Double($0) + 0.5 }) { v in
                AxisValueLabel { Text(names[6 - Int(v.as(Double.self) ?? 0)]) }
            }
        }
        .chartLegend(position: .trailing, alignment: .center)
        .frame(height: 200)
    }

    // MARK: Subscriptions

    private var subscriptions: some View {
        let periods: [PeriodMode] = [.day, .week, .month]
        let spend = Dictionary(uniqueKeysWithValues: periods.map {
            ($0, Grouping.group(state.totals.series(for: $0), by: .source))
        })
        return Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Source").gridColumnAlignment(.leading)
                Text("Fee / month")
                ForEach(periods, id: \.self) { Text("This \($0.label)") }
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(state.sources, id: \.id) { src in
                let fee = src.monthlyFeeUSD
                GridRow {
                    Text(src.id).lineLimit(1)
                    Text(fee > 0 ? usdString(fee) : "—")
                    ForEach(periods, id: \.self) { p in
                        valueCell(api: spend[p]?[src.id]?.usd ?? 0,
                                  fee: Analytics.proratedFee(monthly: fee, period: p))
                    }
                }
                .monospacedDigit()
            }
            Text("Spend is what the same usage would cost at API prices. Set each fee as $/mo under ⚙ → Edit sources (saved in sources.toml as monthly_fee_usd). The fee is prorated per period (a week is 7/365 of a year's fees); × is how many times the fee you got back.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .gridCellColumns(5).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    private func valueCell(api: Double, fee: Double) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(usdString(api))
            if fee > 0 {
                Text("fee \(usdString(fee)) · \(String(format: "%.1f×", api / fee))")
                    .font(.caption2)
                    .foregroundStyle(api >= fee ? .green : .orange)
            }
        }
    }

    // MARK: Formatting

    private func usdString(_ v: Double) -> String {
        // en_US so it reads "$1,234" like the popover, not the system locale's "US$ 1.234".
        v.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US"))
            .precision(.fractionLength(v >= 1000 ? 0 : 2)))
    }

    private func tokenString(_ v: Double) -> String {
        switch v {
        case 1e9...: return String(format: "%.2fB", v / 1e9)
        case 1e6...: return String(format: "%.1fM", v / 1e6)
        case 1e3...: return String(format: "%.1fK", v / 1e3)
        default:     return String(format: "%.0f", v)
        }
    }

    private func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
}
