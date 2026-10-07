import SwiftUI
import AppKit
import Charts
import ClaudeCounterCore

/// The Performance tab's state: the samples from `AppState.performance`
/// and the report built from them. Owned by the dashboard window, which
/// is never released, so the backfill survives closing the window.
///
/// After the first backfill the scanner keeps itself current off the
/// app's file watcher; this model listens for its ticks and rebuilds the
/// report at most every `liveInterval` seconds, and only while the tab is
/// on screen — otherwise it just notes it's stale.
@MainActor
final class PerformanceModel: ObservableObject {
    @Published private(set) var samples: [RequestSample] = []
    @Published private(set) var report: PerformanceReport?
    @Published private(set) var progress: (done: Int, total: Int)?
    @Published private(set) var lastScan: Date?
    @Published private(set) var lastUpdate: Date?
    @Published var filters = PerformanceReport.Filters() { didSet { if filters != oldValue { rebuild() } } }

    /// How far back a backfill reads. The range picker never asks for more.
    static let scanDays = 90
    static let liveInterval: TimeInterval = 5

    private var building: Task<Void, Never>?
    private var listening: Task<Void, Never>?
    private var visible = false
    private var stale = false

    func appeared(_ state: AppState, roots: [String]) async {
        visible = true
        listen(state.performance)
        if lastScan == nil { await backfill(state.performance, roots: roots) }
        else if stale { await refresh(state.performance) }
    }

    func disappeared() { visible = false }

    func backfill(_ scanner: PerformanceScanner, roots: [String]) async {
        guard progress == nil else { return }
        progress = (0, 0)
        await scanner.backfill(roots: roots,
                               notBefore: Date().addingTimeInterval(-Double(Self.scanDays) * 86400)) { done, total in
            Task { @MainActor [weak self] in
                if self?.progress != nil { self?.progress = (done, total) }
            }
        }
        lastScan = Date()
        progress = nil
        await refresh(scanner)
    }

    private func listen(_ scanner: PerformanceScanner) {
        guard listening == nil else { return }
        listening = Task { [weak self] in
            for await _ in scanner.updates {
                guard let self else { return }
                // Coalesce bursts: an active session writes a block every
                // second or two, and a full rebuild is not free.
                try? await Task.sleep(nanoseconds: UInt64(Self.liveInterval * 1_000_000_000))
                if self.visible && self.progress == nil { await self.refresh(scanner) } else { self.stale = true }
            }
        }
    }

    private func refresh(_ scanner: PerformanceScanner) async {
        samples = await scanner.snapshot()
        lastUpdate = Date()
        stale = false
        rebuild()
    }

    /// Statistics over ~150k samples take a moment; keep them off the
    /// main thread and drop superseded builds.
    private func rebuild() {
        building?.cancel()
        let samples = samples, filters = filters
        building = Task {
            let r = await Task.detached(priority: .userInitiated) {
                PerformanceReport.build(samples, filters: filters)
            }.value
            if !Task.isCancelled { report = r }
        }
    }
}

/// The dashboard's Performance tab: latency, estimated decode speed,
/// cache and tool-error proxies per model, from the session logs.
struct PerformanceView: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: PerformanceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controls
                if let r = model.report, !r.models.isEmpty {
                    explainer
                    GroupBox("All models · last \(r.filters.rangeDays) days · click a row to inspect it") { modelTable(r) }
                    kpis(r)
                    section("Speed")
                    grid {
                        GroupBox("E2E request latency") { percentileChart(r, r.e2e) }
                        GroupBox("Time to first block") { percentileChart(r, r.firstBlock) }
                        GroupBox("Est. time to first token @ 50k context") {
                            estimateChart(r, r.fits.map { f in f.map { ($0.ttft, $0.ttftSD) } }, unit: "s")
                        }
                        GroupBox("Est. inter-token latency (ms / token)") {
                            estimateChart(r, r.fits.map { f in f.map { ($0.itlMs, $0.itlSD) } }, unit: "ms")
                        }
                    }
                    section("Load & cache")
                    grid {
                        GroupBox("Concurrency (requests in flight)") {
                            lineChart(r.buckets, [("peak", r.peakInFlight.map { $0.map { Double($0) } }), ("mean", r.meanInFlight)],
                                      colours: [Ramp.q3, Ramp.q1], format: { String(format: "%.1f", $0) })
                        }
                        GroupBox("Your output tokens per minute (load, not speed)") {
                            lineChart(r.buckets, [("output tok/min", r.outputPerMinute)], colours: [.blue], format: { tokenString($0) })
                        }
                        GroupBox("Cache hit rate · \(r.rebuilds) rebuilds") {
                            lineChart(r.buckets, [("hit rate", r.cacheHitRate)], colours: [.blue], format: percent, yDomain: 0...1)
                        }
                        GroupBox("By hour of day (local), median") {
                            hourChart(r)
                        }
                    }
                    section("Quality proxies — they move with task mix too")
                    grid {
                        GroupBox("Tool-call errors (share of tool calls)") {
                            lineChart(r.buckets, [("misuse", r.misuseRate), ("nonzero exit", r.exitRate)],
                                      colours: [.orange, .gray], format: { percent($0, digits: 1) })
                        }
                        GroupBox("Output per request, median tokens") {
                            lineChart(r.buckets, [("output", r.outputP50), ("thinking", r.thinkingP50)],
                                      colours: [.blue, .teal], format: { tokenString($0) })
                        }
                        GroupBox("Tool misuse vs context size") { contextChart(r) }
                    }
                    Text("Misuse = the model's own tool error: stale Edit string, unread file, bad path, invalid input. Nonzero exit is often grep finding nothing; permission blocks and network errors are left out.")
                        .font(.caption).foregroundStyle(.secondary)
                    section("What else changed")
                    grid {
                        GroupBox("Context size (k tokens)") {
                            lineChart(r.buckets, [("p90", r.contextP90.map { $0.map { $0 / 1000 } }), ("p50", r.contextP50.map { $0.map { $0 / 1000 } })],
                                      colours: [Ramp.q3, Ramp.q1], format: { String(format: "%.0fk", $0) })
                        }
                        GroupBox("Effort mix") { effortChart(r) }
                        GroupBox("Subagent share") {
                            lineChart(r.buckets, [("subagent", r.subagentShareByBucket)], colours: [.orange], format: percent, yDomain: 0...1)
                        }
                    }
                } else if model.progress == nil && model.lastScan != nil {
                    Text("No Claude Code requests in the last \(PerformanceModel.scanDays) days.").foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .task { await model.appeared(state, roots: roots) }
        .onDisappear { model.disappeared() }
    }

    private var roots: [String] {
        let r = state.sources.filter { $0.vendor == "claude" }.map(\.root)
        return r.isEmpty ? [state.projectsRoot] : r
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Range", selection: $model.filters.rangeDays) {
                Text("3d").tag(3); Text("7d").tag(7); Text("30d").tag(30); Text("90d").tag(90)
            }
            .pickerStyle(.segmented).frame(width: 200)
            Picker("Bucket", selection: $model.filters.bucket) {
                Text("Auto").tag(PerformanceStats.Bucket?.none)
                ForEach(PerformanceStats.Bucket.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
            }
            .frame(width: 130)
            Picker("Agent", selection: $model.filters.agent) {
                ForEach(PerformanceReport.Agent.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .frame(width: 140)
            Picker("Effort", selection: $model.filters.effort) {
                Text("All").tag(String?.none)
                ForEach(PerformanceReport.efforts, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .frame(width: 130)
            Spacer()
            if let p = model.progress {
                ProgressView().controlSize(.small)
                Text(p.total == 0 ? "Finding files…" : "Reading \(p.done) / \(p.total) files").font(.caption).foregroundStyle(.secondary)
            } else {
                if let t = model.lastUpdate {
                    // style: .relative ticks on its own, so "updated 4s ago" stays true.
                    (Text("● Live · \(model.samples.count.formatted()) requests · updated ") + Text(t, style: .relative) + Text(" ago"))
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Follows the app's file watcher; new requests appear within ~\(Int(PerformanceModel.liveInterval))s of their last block.")
                }
                Button("Rescan") { Task { await model.backfill(state.performance, roots: roots) } }
            }
        }
    }

    private var explainer: some View {
        Text("Session logs record when each content block *completes*, not each token. End-to-end latency and time to first block are measured; TTFT and inter-token latency are estimated per bucket by fitting duration = TTFT + output × ITL + context × c (trimmed least squares, error bars ±2σ). Drift compares the first and last third of the period; it only says \"worse\" or \"better\" past 2σ.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Model table

    private func modelTable(_ r: PerformanceReport) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("Model").gridColumnAlignment(.leading)
                Text("Requests"); Text("E2E p50"); Text("First block p50"); Text("Est. TTFT")
                Text("Est. tok/s"); Text("Misuse"); Text("TTFT drift"); Text("ITL drift"); Text("Misuse drift")
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(r.models) { row in
                GridRow {
                    Text(shortModel(row.model)).lineLimit(1)
                    Text(row.requests.formatted())
                    Text(seconds(row.e2eP50))
                    Text(seconds(row.firstBlockP50))
                    Text(row.fit.map { String(format: "%.2f s", $0.ttft) } ?? "—")
                    Text(row.fit.map { String(format: "%.0f", $0.tokensPerSecond) } ?? "—")
                    Text(row.misuse.map { percent($0, digits: 2) } ?? "—")
                    driftBadge(row.ttftDrift, lowerIsBetter: true, compact: true)
                    driftBadge(row.itlDrift, lowerIsBetter: true, compact: true)
                    driftBadge(row.misuseDrift, lowerIsBetter: true, compact: true, points: true)
                }
                .monospacedDigit()
                .fontWeight(row.model == r.model ? .semibold : nil)
                .foregroundStyle(row.model == r.model ? .primary : .secondary)
                .contentShape(Rectangle())
                .onTapGesture { model.filters.model = row.model }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: KPIs

    private func kpis(_ r: PerformanceReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(shortModel(r.model)).font(.headline)
            HStack(spacing: 10) {
                tile("Requests", r.requests.formatted(), "\(percent(r.subagentShare)) subagent")
                tile("E2E p50", seconds(r.e2eP50), "p90 \(seconds(r.e2eP90))")
                tile("First block p50", seconds(r.firstBlockP50), "p90 \(seconds(r.firstBlockP90))")
                tile("Est. TTFT @ 50k", r.fit.map { String(format: "%.2f s", $0.ttft) } ?? "—",
                     r.fit.map { String(format: "%@%.2f s / 100k ctx", $0.contextCostPer100k >= 0 ? "+" : "−", abs($0.contextCostPer100k)) } ?? "")
                tile("Est. decode", r.fit.map { String(format: "%.0f tok/s", $0.tokensPerSecond) } ?? "—",
                     r.fit.map { String(format: "ITL %.1f ms/token", $0.itlMs) } ?? "")
                tile("Cache hit", r.cacheHit.map { percent($0, digits: 1) } ?? "—", "\(r.rebuilds) rebuilds")
                tile("Tool misuse", r.misuse.map { percent($0, digits: 2) } ?? "—", "of \(r.toolCalls.formatted()) calls")
            }
            HStack(spacing: 10) {
                driftTile("TTFT drift", r.ttftDrift, unit: "s", digits: 2)
                driftTile("Inter-token latency drift", r.itlDrift, unit: "ms", digits: 1)
                driftTile("Tool misuse drift", r.misuseDrift, unit: "", digits: 2, points: true,
                          extra: r.contextBefore.flatMap { a in r.contextAfter.map { String(format: "median ctx %.0fk → %.0fk", a / 1000, $0 / 1000) } })
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func driftTile(_ title: String, _ d: PerformanceStats.Drift?, unit: String, digits: Int,
                           points: Bool = false, extra: String? = nil) -> some View {
        let f = { (v: Double) in points ? percent(v, digits: digits) : String(format: "%.\(digits)f \(unit)", v) }
        return VStack(alignment: .leading, spacing: 2) {
            Text(title + " · first → last third").font(.caption).foregroundStyle(.secondary)
            HStack { driftBadge(d, lowerIsBetter: true, compact: false, points: points) }
            if let d {
                Text("\(f(d.before)) → \(f(d.after)) · ±\(f(d.twoSigma))" + (extra.map { " · \($0)" } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// "+12% worse", "−3% within noise". Status colour plus the word, never colour alone.
    @ViewBuilder
    private func driftBadge(_ d: PerformanceStats.Drift?, lowerIsBetter: Bool, compact: Bool, points: Bool = false) -> some View {
        if let d {
            let change = points ? (d.after - d.before) * 100 : d.relative * 100
            let worse = lowerIsBetter ? d.after > d.before : d.after < d.before
            let tag = !d.significant ? "noise" : worse ? "worse" : "better"
            let colour: Color = !d.significant ? .secondary : worse ? .red : .green
            HStack(spacing: 4) {
                Text(String(format: points ? "%+.2f pp" : "%+.0f%%", change))
                    .font(compact ? .callout : .system(.title3, design: .rounded).weight(.semibold))
                Text(tag).font(.caption2.weight(.medium)).foregroundStyle(colour)
                    .padding(.horizontal, 5).overlay(Capsule().stroke(colour))
            }
            .monospacedDigit()
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    // MARK: Charts

    private struct Pt: Identifiable {
        let series: String, segment: Int, date: Date, value: Double
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    }

    /// Points for one series, split into runs of consecutive buckets with
    /// data. Each run is its own line, so an idle stretch shows as a gap
    /// instead of a straight line drawn across it.
    private func points(_ name: String, _ dates: [Date], _ values: [Double?]) -> [Pt] {
        var out: [Pt] = []
        var seg = 0
        for (d, v) in zip(dates, values) {
            if let v { out.append(Pt(series: name, segment: seg, date: d, value: v)) } else { seg += 1 }
        }
        return out
    }

    private func lineChart(_ dates: [Date], _ series: [(String, [Double?])], colours: [Color],
                           format: @escaping (Double) -> String, yDomain: ClosedRange<Double>? = nil) -> some View {
        let pts = series.flatMap { points($0.0, dates, $0.1) }
        let chart = Chart(pts) { p in
            LineMark(x: .value("Time", p.date), y: .value("Value", p.value), series: .value("Run", "\(p.series)#\(p.segment)"))
                .foregroundStyle(by: .value("Series", p.series))
                .lineStyle(StrokeStyle(lineWidth: 2))
            PointMark(x: .value("Time", p.date), y: .value("Value", p.value))
                .foregroundStyle(by: .value("Series", p.series))
                .symbolSize(18)
        }
        .chartForegroundStyleScale(domain: series.map(\.0), range: colours)
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)) } } } }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 200)
        return Group {
            if let yDomain { chart.chartYScale(domain: yDomain) } else { chart }
        }
    }

    private func percentileChart(_ r: PerformanceReport, _ data: [String: [Double?]]) -> some View {
        let names = PerformanceReport.percentiles.map(\.label).reversed() + ["mean"]
        return lineChart(r.buckets, names.map { ($0, data[$0] ?? []) },
                         colours: [Ramp.q4, Ramp.q3, Ramp.q2, Ramp.q1, .orange], format: { String(format: "%.0f s", $0) })
    }

    /// Estimate per bucket with a ±2σ error bar. Error bars rather than a
    /// band: a band has to be bridged across gaps, a bar never is.
    private func estimateChart(_ r: PerformanceReport, _ values: [(Double, Double)?], unit: String) -> some View {
        let rows = zip(r.buckets, values).compactMap { d, v in v.map { (d, $0.0, $0.1) } }
        let pts = points("estimate", r.buckets, values.map { $0?.0 })
        return Chart {
            ForEach(rows, id: \.0) { d, v, sd in
                RuleMark(x: .value("Time", d), yStart: .value("lo", max(0, v - 2 * sd)), yEnd: .value("hi", v + 2 * sd))
                    .foregroundStyle(Color.blue.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 3))
            }
            ForEach(pts) { p in
                LineMark(x: .value("Time", p.date), y: .value("Value", p.value), series: .value("Run", p.segment))
                    .foregroundStyle(Color.blue)
                PointMark(x: .value("Time", p.date), y: .value("Value", p.value)).foregroundStyle(Color.blue).symbolSize(14)
            }
        }
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.1f \(unit)", d)) } } } }
        .frame(height: 200)
    }

    private struct HourPt: Identifiable {
        let series: String, segment: Int, hour: Int, value: Double
        var id: String { "\(series)-\(hour)" }
    }

    private func hourChart(_ r: PerformanceReport) -> some View {
        // Same gap rule as `points`: hours without data break the line.
        let rows = [("E2E", r.hourE2E), ("first block", r.hourFirstBlock)].flatMap { name, values in
            var seg = 0
            return (0..<24).compactMap { h -> HourPt? in
                guard let v = values[h] else { seg += 1; return nil }
                return HourPt(series: name, segment: seg, hour: h, value: v)
            }
        }
        return Chart(rows) { p in
            LineMark(x: .value("Hour", p.hour), y: .value("Seconds", p.value), series: .value("Run", "\(p.series)#\(p.segment)"))
                .foregroundStyle(by: .value("Series", p.series))
            PointMark(x: .value("Hour", p.hour), y: .value("Seconds", p.value)).foregroundStyle(by: .value("Series", p.series)).symbolSize(12)
        }
        .chartForegroundStyleScale(domain: ["E2E", "first block"], range: [Ramp.q3, Ramp.q1])
        .chartXScale(domain: 0...23)
        .chartXAxis { AxisMarks(values: Array(stride(from: 0, through: 23, by: 3))) { v in
            AxisGridLine(); AxisValueLabel { Text(String(format: "%02d", v.as(Int.self) ?? 0)) } } }
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.0f s", d)) } } } }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 200)
    }

    private struct BinPt: Identifiable {
        let label: String, value: Double
        var id: String { label }
    }

    private func contextChart(_ r: PerformanceReport) -> some View {
        let rows = zip(PerformanceReport.contextBins.map(\.label), r.misuseByContext).compactMap { l, v in v.map { BinPt(label: l, value: $0) } }
        return Chart(rows) { p in
            LineMark(x: .value("Context", p.label), y: .value("Misuse", p.value)).foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 2))
            PointMark(x: .value("Context", p.label), y: .value("Misuse", p.value)).foregroundStyle(Color.orange).symbolSize(24)
        }
        .chartXScale(domain: PerformanceReport.contextBins.map(\.label))
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(percent(d, digits: 1)) } } } }
        .frame(height: 200)
    }

    /// One line per effort level, its share of the bucket's requests.
    /// Levels never used in the range are left out rather than drawn
    /// as a flat line at 0%.
    private func effortChart(_ r: PerformanceReport) -> some View {
        let colours: [Color] = [.gray, Ramp.q1, Ramp.q2, Ramp.q3, Ramp.q4]
        let used = PerformanceReport.efforts.indices.filter { i in
            (r.effortShare[PerformanceReport.efforts[i]] ?? []).contains { ($0 ?? 0) > 0 }
        }
        return lineChart(r.buckets, used.map { (PerformanceReport.efforts[$0], r.effortShare[PerformanceReport.efforts[$0]] ?? []) },
                         colours: used.map { colours[$0] }, format: percent, yDomain: 0...1)
    }

    // MARK: Layout & formatting

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 12)], alignment: .leading, spacing: 12, content: content)
    }

    private func seconds(_ v: Double?) -> String { v.map { String(format: "%.1f s", $0) } ?? "—" }
}

/// Ordered blue ramp for percentiles and effort levels: p50 nearest the
/// background, p99 strongest. Separate light and dark steps so the
/// faintest still reads on either background.
private enum Ramp {
    static let q1 = adaptive(0x86b6ef, 0x184f95)
    static let q2 = adaptive(0x3987e5, 0x256abf)
    static let q3 = adaptive(0x1c5cab, 0x5598e7)
    static let q4 = adaptive(0x0d366b, 0x9ec5f4)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}

private func shortModel(_ m: String) -> String {
    m.hasPrefix("claude-") ? String(m.dropFirst("claude-".count)) : m
}

private func percent(_ v: Double) -> String { percent(v, digits: 0) }
private func percent(_ v: Double, digits: Int) -> String { String(format: "%.\(digits)f%%", v * 100) }

private func tokenString(_ v: Double) -> String {
    switch v {
    case 1e6...: return String(format: "%.1fM", v / 1e6)
    case 1e3...: return String(format: "%.1fK", v / 1e3)
    default: return String(format: "%.0f", v)
    }
}
