import SwiftUI
import AppKit
import ClaudeCounterCore

/// The dashboard's Hints tab: what is costing the most and the one-line
/// change that would cut it. Built on the Performance tab's samples, so
/// opening either tab first does the same single backfill.
struct HintsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: PerformanceModel

    @State private var days = 7
    @State private var hints: [Hint]?
    @State private var spend: Double = 0
    @State private var copied: Hint.Kind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker("Period", selection: $days) {
                        Text("Last 7 days").tag(7); Text("Last 30 days").tag(30); Text("Last 90 days").tag(90)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 330)
                    Spacer()
                    if let p = model.progress {
                        ProgressView().controlSize(.small)
                        Text(p.total == 0 ? "Finding files…" : "Reading \(p.done) / \(p.total) files")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if hints != nil {
                        Text("\(usd(spend)) spent in the period at API prices").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Estimates from your session logs, at flat API prices (no long-context premium, so turns above 200k run a little higher). Savings overlap — compacting earlier also shrinks resume rewrites — so don't add them up. Fixes are settings for ~/.claude/settings.json; this app only reads that file.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hints {
                    if hints.isEmpty {
                        Label("Nothing worth changing in this period.", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary).padding(.top, 8)
                    }
                    ForEach(hints) { card($0) }
                } else if model.progress == nil {
                    HStack { ProgressView().controlSize(.small); Text("Working out hints…").foregroundStyle(.secondary) }
                }
            }
            .padding(16)
        }
        .task { await model.appeared(state, roots: roots) }
        .onDisappear { model.disappeared() }
        // Recompute when the data, the prices or the period change.
        .task(id: "\(model.samples.count)|\(model.lastUpdate?.timeIntervalSince1970 ?? 0)|\(days)") { await recompute() }
    }

    private var roots: [String] {
        let r = state.sources.filter { $0.vendor == "claude" }.map(\.root)
        return r.isEmpty ? [state.projectsRoot] : r
    }

    private func recompute() async {
        guard !model.samples.isEmpty else { return }
        let samples = model.samples, pricing = state.pricing, days = days
        let (h, s) = await Task.detached(priority: .userInitiated) { () -> ([Hint], Double) in
            let since = Date().addingTimeInterval(-Double(days) * 86400)
            let spend = samples.filter { $0.time >= since }.reduce(0) { $0 + $1.cost(pricing) }
            return (Hints.build(samples, pricing: pricing, settings: ClaudeSettingsSnapshot.load(), days: days), spend)
        }.value
        hints = h
        spend = s
    }

    // MARK: Card

    private func card(_ h: Hint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon(h.id)).foregroundStyle(.secondary).frame(width: 18)
                Text(h.title).font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("≈ \(usd(h.savingUSD))").font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                    Text(days == 30 ? "in 30 days" : "in \(days) days · ≈ \(usd(h.savingUSD * 30 / Double(days)))/month")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(h.finding).fixedSize(horizontal: false, vertical: true)
            Text(h.fix).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let snippet = h.snippet {
                HStack(spacing: 8) {
                    Text(snippet).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    Button(copied == h.id ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snippet, forType: .string)
                        copied = h.id
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let applied = h.applied {
                    // Status = icon + words, never colour alone.
                    Label("Applied", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
                    Text(applied).font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Trade-off", systemImage: "exclamationmark.triangle").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    Text(h.caveat).font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(h.applied != nil ? Color.green.opacity(0.5) : .clear))
    }

    private func icon(_ k: Hint.Kind) -> String {
        switch k {
        case .compact: return "rectangle.compress.vertical"
        case .resume: return "pause.circle"
        case .cacheTTL: return "clock.arrow.circlepath"
        case .subagentModel: return "person.2"
        case .mainModel: return "cpu"
        case .effort: return "gauge.with.dots.needle.33percent"
        }
    }

    private func usd(_ v: Double) -> String {
        v.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(v >= 100 ? 0 : 2)))
    }
}
