import SwiftUI
import AppKit
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

    /// User-adjustable popover height, dragged via the grip at the bottom
    /// and persisted so a relaunch keeps the chosen size. Clamped to
    /// `heightRange` so it can never collapse the dashboard or grow past a
    /// reasonable screen height.
    @AppStorage("ClaudeCounterBar.popoverHeight") private var popoverHeight: Double = 700
    /// Height captured at the start of a resize drag, so the gesture's
    /// cumulative translation maps to an absolute height.
    @State private var dragBaseHeight: Double? = nil
    private let heightRange: ClosedRange<Double> = 460...1200
    /// Day (YYYY-MM-DD) the hourly chart is drilled into, set by
    /// clicking a bar in either monthly chart. `nil` → today. Stored
    /// as the day string (not an index) so it stays pinned to the same
    /// calendar day as snapshots shift the 30-day window.
    @State private var selectedDay: String? = nil

    /// Cap each table at the top-N rows by USD. Anything beyond is
    /// reachable via the TUI / `claudecounter --once` — the menu bar
    /// is a glanceable surface, not the full ledger.
    private let topN = 8

    /// Computed once per view body so both monthly charts AND the
    /// by-model table share the same model→colour mapping. Recomputed
    /// every snapshot publish (cheap — small dictionary), so the
    /// palette stays in sync with the data the UI is currently showing.
    private var palette: ModelPalette {
        ModelPalette(monthUSD: state.totals.month, dailyWindow: state.totals.daily)
    }

    /// Day key of "today" — always the last entry of the daily window.
    private var todayKey: String? { state.totals.daily.last?.day }

    /// The day the hourly chart shows: the clicked day if it's still in
    /// the window, else today. Selecting today is the same as clearing.
    private var shownEntry: DailyTotal? {
        guard let sel = selectedDay, sel != todayKey else { return state.totals.daily.last }
        return state.totals.daily.first(where: { $0.day == sel }) ?? state.totals.daily.last
    }

    var body: some View {
        let shown = shownEntry
        let showingToday = shown == nil || shown?.day == todayKey

        VStack(alignment: .leading, spacing: 12) {
            // Pinned-top: identity + charts. These are the "glance"
            // surface and must always be visible.
            HeroRow(state: state)
            HourlyChartRow(
                day: shown?.day ?? "",
                hourlyUSDByModel: shown?.hourlyUSDByModel ?? Array(repeating: [:], count: 24),
                palette: palette,
                isToday: showingToday,
                onReturnToToday: { selectedDay = nil }
            )
            MonthlyChartRow(daily: state.totals.daily, palette: palette,
                            selectedDay: showingToday ? nil : selectedDay,
                            onSelectDay: select(day:))
            MonthlyTokenChartRow(daily: state.totals.daily, palette: palette,
                                 selectedDay: showingToday ? nil : selectedDay,
                                 onSelectDay: select(day:))

            // Scrollable middle: tables + live tail. Sized to fill
            // remaining vertical space.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 16) {
                        ByModelTable(month: state.totals.month, topN: topN, palette: palette)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ByProjectTable(month: state.totals.monthProj)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ActiveSessionsSection(sessions: state.activeSessions)
                }
            }
            .frame(maxHeight: .infinity)

            // Pinned-bottom: refresh + settings.
            FooterRow(
                state: state,
                refreshing: $refreshing,
                showSettings: $showSettings
            )

            // Drag grip: MenuBarExtra windows can't be OS-resized, so we
            // give the user a handle to grow/shrink the popover. The height
            // is persisted via @AppStorage.
            ResizeGrip { delta in
                let base = dragBaseHeight ?? popoverHeight
                if dragBaseHeight == nil { dragBaseHeight = base }
                popoverHeight = min(heightRange.upperBound,
                                    max(heightRange.lowerBound, base + delta))
            } onEnded: {
                dragBaseHeight = nil
            }
        }
        .padding(14)
        .frame(width: 520, height: popoverHeight)
    }

    /// Toggle semantics: clicking the already-selected day (or today's
    /// bar) returns the hourly chart to today.
    private func select(day: String) {
        if day == selectedDay || day == todayKey {
            selectedDay = nil
        } else {
            selectedDay = day
        }
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

/// Per-hour spend for one day — today by default, or any day the user
/// clicked in the monthly chart. Bars are stacked by model with the
/// SAME palette as the monthly charts, so a model keeps its colour
/// across every chart in the popover.
struct HourlyChartRow: View {
    /// YYYY-MM-DD of the day being shown.
    let day: String
    /// 24 entries of model → USD for that day's hours.
    let hourlyUSDByModel: [[String: Double]]
    let palette: ModelPalette
    let isToday: Bool
    /// Invoked by the "Today" button shown while a past day is displayed.
    let onReturnToToday: () -> Void
    @State private var hoveredHour: Int? = nil

    private var hourlyUSD: [Double] {
        hourlyUSDByModel.map { $0.values.reduce(0, +) }
    }

    var body: some View {
        let totals = hourlyUSD
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(isToday ? "Today's spend (per hour)"
                             : "\(formatDayLong(day)) · spend per hour")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isToday ? AnyShapeStyle(.secondary)
                                             : AnyShapeStyle(.primary))
                if !isToday {
                    // Clear affordance back to today, mirroring the
                    // click-to-drill that got the user here.
                    Button(action: onReturnToToday) {
                        Label("Today", systemImage: "xmark.circle.fill")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                // Inline readout for the hovered hour. Lives in the
                // section header so it doesn't reflow the chart.
                if let h = hoveredHour, h < totals.count {
                    HStack(spacing: 4) {
                        Text(formatHour(h))
                            .foregroundStyle(.primary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(formatUSDFine(totals[h]))
                            .foregroundStyle(totals[h] > 0 ? .green : .secondary)
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .frame(height: 12)

            GeometryReader { geo in
                let maxV = max(totals.max() ?? 0, 0.0001)
                let nowHour = Calendar.current.component(.hour, from: Date())
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<totals.count, id: \.self) { hour in
                        StackedDailyBar(
                            byModel: hourlyUSDByModel[hour],
                            total: totals[hour],
                            maxV: maxV,
                            availableHeight: geo.size.height,
                            palette: palette,
                            isToday: isToday && hour == nowHour,
                            isHovered: hour == hoveredHour,
                            // Future hours (today only) dim harder than
                            // past zero hours, matching the old chart.
                            zeroValueTint: Color.gray.opacity(
                                isToday && hour > nowHour ? 0.20 : 0.30)
                        )
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
                                                count: totals.count)
                    case .ended:
                        hoveredHour = nil
                    }
                }
            }
            .frame(height: 56)
        }
        .animation(.easeInOut(duration: 0.12), value: hoveredHour)
        .animation(.easeInOut(duration: 0.12), value: day)
    }

    /// Map an x-coordinate inside the chart to one of the 24 hour
    /// buckets. Even spacing → integer division by per-bar slot width.
    private func hourIndex(for x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0, x >= 0, x <= width else { return nil }
        let slot = width / CGFloat(count)
        let idx = Int((x / slot).rounded(.down))
        return min(max(idx, 0), count - 1)
    }

    private func formatHour(_ h: Int) -> String {
        String(format: "%02d:00", h)
    }

    /// "2026-04-26" → "Sun, Apr 26" — an unambiguous date for the
    /// drilled-in header.
    private func formatDayLong(_ ymd: String) -> String {
        let inFmt = DateFormatter()
        inFmt.dateFormat = "yyyy-MM-dd"
        guard let d = inFmt.date(from: ymd) else { return ymd }
        let outFmt = DateFormatter()
        outFmt.dateFormat = "EEE, MMM d"
        outFmt.locale = Locale(identifier: "en_US_POSIX")
        return outFmt.string(from: d)
    }
}

// MARK: - Monthly chart (last 30 days)

/// One bar per day for the last 30 days, oldest → newest. Same hover
/// idiom as `HourlyChartRow`: pointer over a bar highlights it and
/// shows `YYYY-MM-DD · $X.XX` in the section header.
struct MonthlyChartRow: View {
    let daily: [DailyTotal]
    let palette: ModelPalette
    /// Day currently drilled into by the hourly chart (nil = today).
    /// The matching bar gets an accent outline.
    var selectedDay: String? = nil
    /// Called with the clicked bar's day so the popover can drill the
    /// hourly chart into it.
    var onSelectDay: ((String) -> Void)? = nil
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
                        StackedDailyBar(
                            byModel: entry.usdByModel,
                            total: entry.usd,
                            maxV: maxV,
                            availableHeight: geo.size.height,
                            palette: palette,
                            isToday: idx == daily.count - 1,
                            isHovered: idx == hoveredIndex,
                            isSelected: daily[idx].day == selectedDay,
                            zeroValueTint: Color.gray.opacity(0.30)
                        )
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
                // Click a bar → drill the hourly chart into that day.
                .onTapGesture(coordinateSpace: .local) { point in
                    if let idx = barIndex(for: point.x,
                                          width: geo.size.width,
                                          count: daily.count) {
                        onSelectDay?(daily[idx].day)
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

/// One day's stacked bar, height proportional to its (USD or token)
/// total against the whole window's max, internal segments sized
/// proportional to each model's share of that day.
///
/// Used by both `MonthlyChartRow` (USD) and `MonthlyTokenChartRow`
/// (tokens) — generic over `Numeric & BinaryFloatingPoint`-ish via
/// the `Double` conversion the caller does.
///
/// Stacking order is GLOBAL (from the palette), not per-day, so a
/// model's colour stays at the same vertical position whether or not
/// it's the top spender on a given day. That makes the chart easier
/// to read horizontally — the eye picks out the "blue band" running
/// across days even as its height varies.
///
/// Empty days (zero total) render a thin grey track so the day
/// position is still visible on the timeline.
struct StackedDailyBar: View {
    let byModel: [String: Double]
    let total: Double
    let maxV: Double
    let availableHeight: CGFloat
    let palette: ModelPalette
    let isToday: Bool
    let isHovered: Bool
    /// True when this bar's day is the one the hourly chart is drilled
    /// into — gets an accent outline so the link between the two charts
    /// is visible.
    var isSelected: Bool = false
    /// Colour for a zero-total day — a muted track so the timeline
    /// gap is visible without competing with real data.
    let zeroValueTint: Color

    var body: some View {
        let totalHeight = max(2, CGFloat(total / maxV) * availableHeight)
        if total <= 0 {
            // Zero day: thin muted track. Still outlined when selected
            // so drilling into an empty day has visible feedback.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(zeroValueTint)
                .frame(height: totalHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 1.5)
                        .stroke(isSelected ? Color.accentColor : Color.clear,
                                lineWidth: isSelected ? 1 : 0)
                )
        } else {
            // Build segment rectangles in global model order so the
            // vertical placement of each colour stays stable across
            // days. Smallest-index models go to the BOTTOM of the
            // stack (foundational), larger indices stack on top.
            VStack(spacing: 0) {
                // Top → bottom in palette.order.reversed(), so palette
                // index 0 (top spender, e.g. opus) is at the BOTTOM
                // of the stack — the conventional "foundation" colour.
                ForEach(Array(palette.order.reversed().enumerated()), id: \.element) { _, model in
                    let v = byModel[model] ?? 0
                    if v > 0 {
                        Rectangle()
                            .fill(segmentColor(for: model))
                            .frame(height: max(0.5, totalHeight * CGFloat(v / total)))
                    }
                }
            }
            .frame(height: totalHeight)
            .clipShape(RoundedRectangle(cornerRadius: 1.5))
            // Selected bar gets a vivid accent outline (it's the day
            // the hourly chart is showing); otherwise today's bar gets
            // a thin outline so the eye lands on it even when its
            // height isn't the chart's max.
            .overlay(
                RoundedRectangle(cornerRadius: 1.5)
                    .stroke(isSelected ? Color.accentColor
                            : (isToday ? Color.primary.opacity(0.55) : Color.clear),
                            lineWidth: isSelected ? 1 : (isToday ? 0.6 : 0))
            )
            // Hover: brighten the whole stack by overlaying a faint
            // primary colour. Subtler than swapping every segment to
            // a single colour (which would lose the breakdown info).
            .overlay(
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(isHovered ? 0.18 : 0))
            )
        }
    }

    private func segmentColor(for model: String) -> Color {
        let base = palette.colour(for: model)
        // Slight transparency on non-hovered, non-today days keeps
        // the chart from looking like a candy-coloured wall when 30
        // days are stacked next to each other; today/hovered days
        // pop at full saturation.
        if isHovered || isToday { return base }
        return base.opacity(0.78)
    }
}

// MARK: - Monthly token chart (last 30 days, parallel to MonthlyChartRow)

/// One bar per day for the last 30 days, oldest → newest, plotting
/// total tokens (input + output + cache-create + cache-read) instead
/// of USD. Hover surfaces both the token count AND the cost for that
/// day, so the user can answer "did I spend more because I used the
/// API more, or because the model was more expensive?" in one glance.
///
/// Colour scheme deliberately differs from `MonthlyChartRow` (blue
/// vs green) so the two stacked charts stay visually distinct at a
/// glance — the eye reads "this row is tokens, not money."
struct MonthlyTokenChartRow: View {
    let daily: [DailyTotal]
    let palette: ModelPalette
    /// Same click-to-drill wiring as `MonthlyChartRow` — both charts
    /// plot the same days, so clicking either selects the day.
    var selectedDay: String? = nil
    var onSelectDay: ((String) -> Void)? = nil
    @State private var hoveredIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Last 30 days · tokens")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let i = hoveredIndex, i < daily.count {
                    HStack(spacing: 4) {
                        Text(formatDay(daily[i].day))
                            .foregroundStyle(.primary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(formatTokens(daily[i].tokens))
                            .foregroundStyle(daily[i].tokens > 0 ? .blue : .secondary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(formatUSDFine(daily[i].usd))
                            .foregroundStyle(daily[i].usd > 0 ? .green : .secondary)
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                } else {
                    Text(summary)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(height: 12)

            GeometryReader { geo in
                let maxV = max(Double(daily.map { $0.tokens }.max() ?? 0), 1)
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(Array(daily.enumerated()), id: \.offset) { idx, entry in
                        // Convert tokensByModel (UInt64) → Double for
                        // the shared StackedDailyBar machinery, and
                        // keep the SAME palette so a model's colour
                        // matches between the two charts.
                        StackedDailyBar(
                            byModel: entry.tokensByModel.mapValues { Double($0) },
                            total: Double(entry.tokens),
                            maxV: maxV,
                            availableHeight: geo.size.height,
                            palette: palette,
                            isToday: idx == daily.count - 1,
                            isHovered: idx == hoveredIndex,
                            isSelected: daily[idx].day == selectedDay,
                            zeroValueTint: Color.gray.opacity(0.30)
                        )
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
                .onTapGesture(coordinateSpace: .local) { point in
                    if let idx = barIndex(for: point.x,
                                          width: geo.size.width,
                                          count: daily.count) {
                        onSelectDay?(daily[idx].day)
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

    private var summary: String {
        let totalTokens: UInt64 = daily.reduce(0) { $0 &+ $1.tokens }
        let totalUSD = daily.reduce(0) { $0 + $1.usd }
        guard let first = daily.first?.day, let last = daily.last?.day else {
            return "no data"
        }
        return "\(formatDay(first))…\(formatDay(last)) · \(formatTokens(totalTokens)) · \(formatUSDCompact(totalUSD))"
    }

    /// "2026-04-26" → "Apr 26" (same DateFormatter dance as the USD
    /// chart — duplicated here intentionally to keep this view file-
    /// scoped without a shared helper that could become stale).
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
    /// Same palette the monthly charts use — passed in so the small
    /// colour swatch next to each model name matches its bar segment
    /// in the chart, making this table a self-explanatory legend.
    let palette: ModelPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("By model · month")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { name, usd, pct in
                HStack(spacing: 6) {
                    // Tiny colour swatch — same colour the model has
                    // in the stacked bars above, so the user can
                    // visually trace a row to its segment.
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(palette.colour(for: name))
                        .frame(width: 8, height: 8)
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
    /// Number of rows shown before the list becomes scrollable. Roughly
    /// five two-line rows fit in `visibleHeight`; the rest are reachable by
    /// scrolling inside this table (independent of the outer scroll view).
    private let visibleRows = 5
    private let rowHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("By project · month (M / sub)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if sortedRows.count > visibleRows {
                    Text("\(sortedRows.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if sortedRows.isEmpty {
                Text("No projects yet this month")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sortedRows, id: \.0) { name, total, main, sub in
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
                    }
                }
                // Cap the visible area at ~5 rows; scroll for the rest.
                .frame(maxHeight: CGFloat(visibleRows) * rowHeight)
            }
        }
    }

    private var sortedRows: [(String, Double, Double, Double)] {
        month
            .map { (name: $0.key, total: $0.value.totalUSD, main: $0.value.mainUSD, sub: $0.value.subUSD) }
            .sorted { $0.total > $1.total }
            .map { ($0.name, $0.total, $0.main, $0.sub) }
    }

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

// MARK: - Active sessions

/// Live sessions (last turn within the active window), replacing the old
/// per-event live tail. Each row is a two-line summary: identity + total
/// cost on top, the glanceable metrics (context %, 5-minute cost, turns,
/// wall-clock age) plus warning glyphs below.
struct ActiveSessionsSection: View {
    let sessions: [SessionStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Active sessions")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !sessions.isEmpty {
                    Text("\(sessions.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sessions.prefix(8)) { s in
                        ActiveSessionRow(session: s)
                    }
                    if sessions.isEmpty {
                        Text("No active sessions")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }
}

struct ActiveSessionRow: View {
    let session: SessionStat

    private var warned: Bool { !session.warnings.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Line 1: project · model · total cost.
            HStack(spacing: 6) {
                Text(shortProject(session.project))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Text(shortModel(session.model))
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
                Spacer()
                WarningGlyphs(warnings: session.warnings)
                Text(formatUSDCompact(session.costUSD))
                    .foregroundStyle(warned ? .orange : .secondary)
                    .monospacedDigit()
            }
            .font(.system(size: 12))

            // Line 2: context %, 5-minute cost, turns, age.
            HStack(spacing: 8) {
                ContextBar(pct: session.contextPct,
                           warn: session.warnings.contains(.context))
                Text("5m \(formatUSDFine(session.cost5mUSD))")
                    .foregroundStyle(session.cost5mUSD > 0 ? .green : .secondary)
                Text("\(session.turns)t")
                    .foregroundStyle(session.warnings.contains(.turns) ? .orange : .secondary)
                Text(formatAge(session.ageSeconds))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.system(size: 10, design: .rounded))
            .monospacedDigit()
        }
    }

    private func shortProject(_ encoded: String) -> String {
        shortProjectName(encoded)
    }

    private func shortModel(_ id: String) -> String {
        if id.contains("opus")   { return "opus" }
        if id.contains("sonnet") { return "sonnet" }
        if id.contains("haiku")  { return "haiku" }
        if id.contains("fable")  { return "fable" }
        return id
    }

    /// "1h20m", "12m", "45s" — compact wall-clock age.
    private func formatAge(_ secs: Int) -> String {
        if secs >= 3600 { return "\(secs / 3600)h\((secs % 3600) / 60)m" }
        if secs >= 60 { return "\(secs / 60)m" }
        return "\(secs)s"
    }
}

/// Thin proportional context-occupancy bar with an inline percentage.
struct ContextBar: View {
    let pct: Double
    let warn: Bool

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.gray.opacity(0.25))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(warn ? Color.orange : Color.accentColor)
                        .frame(width: max(1, geo.size.width * CGFloat(min(1, max(0, pct)))))
                }
            }
            .frame(width: 40, height: 5)
            Text("ctx \(Int((pct * 100).rounded()))%")
                .foregroundStyle(warn ? .orange : .secondary)
        }
    }
}

/// Warning badge glyphs shown at the right of a session's first line.
struct WarningGlyphs: View {
    let warnings: SessionWarnings

    var body: some View {
        HStack(spacing: 3) {
            if warnings.contains(.context) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Context nearly full")
            }
            if warnings.contains(.cache) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
                    .help("High cache-creation spend")
            }
            if warnings.contains(.turns) {
                Image(systemName: "clock.badge.exclamationmark.fill")
                    .foregroundStyle(.yellow)
                    .help("Session running long (many turns)")
            }
        }
        .font(.system(size: 10))
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
                Toggle("Session alerts (notifications)", isOn: Binding(
                    get: { state.settings.notificationsEnabled },
                    set: { newValue in state.setNotificationsEnabled(newValue) }
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

// MARK: - Resize grip

/// A slim handle pinned to the bottom of the popover. Dragging it
/// vertically reports the cumulative translation so the parent can grow
/// or shrink its persisted height. Pure vertical resize — the width is
/// fixed. Shows a resize cursor on hover so the affordance is discoverable.
struct ResizeGrip: View {
    /// Called with the drag's cumulative vertical translation (points).
    let onDrag: (Double) -> Void
    /// Called when the drag ends, so the parent can reset its drag base.
    let onEnded: () -> Void

    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 40, height: 4)
            .frame(maxWidth: .infinity)          // center the handle
            .contentShape(Rectangle())           // enlarge the hit target
            .padding(.top, 2)
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in onDrag(value.translation.height) }
                    .onEnded { _ in onEnded() }
            )
            .help("Drag to resize")
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
