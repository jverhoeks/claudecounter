import SwiftUI
import AppKit

/// A weekday × hour grid drawn as a continuous heat field rather than
/// tiles: each cell's value is spread with a Gaussian kernel and the
/// smoothed surface is coloured on a dark → blue → cyan → yellow → red
/// heat scale. Smoothing happens on the values, before colouring, so
/// neighbouring busy hours merge into one glow instead of showing seams.
///
/// The readout under the pointer always reports the raw cell value, not
/// the smoothed one, so the blur never invents a number.
struct HeatField: View {
    /// rows × columns, row 0 drawn at the top.
    let grid: [[Double]]
    let rowLabels: [String]
    let format: (Double) -> String

    @State private var hover: (row: Int, col: Int, point: CGPoint)?

    private var rows: Int { grid.count }
    private var cols: Int { grid.first?.count ?? 0 }

    /// Scale tops out at the 95th percentile of active cells, so one
    /// outlier hour doesn't leave everything else cold.
    private var cap: Double {
        let active = grid.flatMap { $0 }.filter { $0 > 0 }.sorted()
        guard !active.isEmpty else { return 1 }
        return max(active[Int(Double(active.count - 1) * 0.95)], 0.01)
    }

    var body: some View {
        let cap = self.cap
        let image = HeatField.render(grid, cap: cap)
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(rowLabels.indices, id: \.self) { i in
                    Text(rowLabels[i]).font(.caption).foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 30)
            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable().interpolation(.high)
                        if let h = hover { crosshair(h, size: geo.size) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let c = min(max(Int(p.x / geo.size.width * CGFloat(cols)), 0), cols - 1)
                            let r = min(max(Int(p.y / geo.size.height * CGFloat(rows)), 0), rows - 1)
                            hover = (r, c, p)
                        case .ended:
                            hover = nil
                        }
                    }
                }
                hourAxis
            }
            legend(cap)
        }
        .frame(height: 220)
    }

    private func crosshair(_ h: (row: Int, col: Int, point: CGPoint), size: CGSize) -> some View {
        let cx = (CGFloat(h.col) + 0.5) / CGFloat(cols) * size.width
        let cy = (CGFloat(h.row) + 0.5) / CGFloat(rows) * size.height
        let label = "\(rowLabels[h.row]) \(String(format: "%02d:00", h.col)) · \(format(grid[h.row][h.col]))"
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: cx, y: 0)); p.addLine(to: CGPoint(x: cx, y: size.height))
                p.move(to: CGPoint(x: 0, y: cy)); p.addLine(to: CGPoint(x: size.width, y: cy))
            }
            .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Text(label)
                .font(.caption.monospacedDigit()).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                // Keep the readout inside the plot near the right/bottom edges.
                .offset(x: min(cx + 8, size.width - 150), y: cy > size.height - 28 ? cy - 26 : cy + 6)
        }
        .allowsHitTesting(false)
    }

    private var hourAxis: some View {
        GeometryReader { geo in
            ForEach(Array(stride(from: 0, to: cols, by: 3)), id: \.self) { h in
                Text(String(format: "%02d", h)).font(.caption).foregroundStyle(.secondary)
                    .position(x: (CGFloat(h) + 0.5) / CGFloat(cols) * geo.size.width, y: 7)
            }
        }
        .frame(height: 14)
    }

    private func legend(_ cap: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(format(cap) + "+").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(stops: HeatField.stops.reversed().map { .init(color: Color(nsColor: $0.1), location: 1 - $0.0) },
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 10)
            }
            Text(format(0)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.bottom, 18)
    }

    // MARK: Rendering

    /// Dark navy at zero, then blue, cyan, yellow, orange, red.
    static let stops: [(Double, NSColor)] = [
        (0.00, rgb(0x0d1330)), (0.15, rgb(0x153b8f)), (0.35, rgb(0x1f8fd6)), (0.55, rgb(0x3fd1c7)),
        (0.72, rgb(0xf2d14b)), (0.86, rgb(0xf08a24)), (1.00, rgb(0xe8412c)),
    ]

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    private static func colour(_ t: Double) -> (UInt8, UInt8, UInt8) {
        let t = min(max(t, 0), 1)
        var lo = stops[0], hi = stops[stops.count - 1]
        for i in 1..<stops.count where t <= stops[i].0 { lo = stops[i - 1]; hi = stops[i]; break }
        let f = hi.0 == lo.0 ? 0 : (t - lo.0) / (hi.0 - lo.0)
        func ch(_ a: CGFloat, _ b: CGFloat) -> UInt8 { UInt8(max(0, min(255, (a + (b - a) * CGFloat(f)) * 255))) }
        let a = lo.1.usingColorSpace(.sRGB)!, b = hi.1.usingColorSpace(.sRGB)!
        return (ch(a.redComponent, b.redComponent), ch(a.greenComponent, b.greenComponent), ch(a.blueComponent, b.blueComponent))
    }

    /// Pixels per cell. 7 × 24 cells → a 384 × 112 image, upscaled smoothly.
    private static let scale = 16
    /// Kernel width in cells: wide enough to merge neighbours, narrow
    /// enough that a single busy hour still reads as its own spot.
    private static let sigma = 0.6

    private static var cache: (key: [[Double]], cap: Double, image: NSImage)?

    static func render(_ grid: [[Double]], cap: Double) -> NSImage {
        if let c = cache, c.key == grid, c.cap == cap { return c.image }
        let rows = grid.count, cols = grid.first?.count ?? 0
        let w = max(cols * scale, 1), h = max(rows * scale, 1)
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let reach = Int((3 * sigma).rounded(.up))
        for y in 0..<h {
            let cy = (Double(y) + 0.5) / Double(scale) - 0.5
            for x in 0..<w {
                let cx = (Double(x) + 0.5) / Double(scale) - 0.5
                // Kernel-weighted average of nearby cells (empty ones count
                // as zero, so a lone busy hour fades out into the dark).
                var num = 0.0, den = 0.0
                for r in max(0, Int(cy) - reach)...min(rows - 1, Int(cy) + reach + 1) {
                    for c in max(0, Int(cx) - reach)...min(cols - 1, Int(cx) + reach + 1) {
                        let d2 = (Double(r) - cy) * (Double(r) - cy) + (Double(c) - cx) * (Double(c) - cx)
                        let k = exp(-d2 / (2 * sigma * sigma))
                        num += k * grid[r][c]; den += k
                    }
                }
                let (cr, cg, cb) = colour(den > 0 ? num / den / cap : 0)
                let i = (y * w + x) * 4
                px[i] = cr; px[i + 1] = cg; px[i + 2] = cb
            }
        }
        let image: NSImage = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let cg = ctx.makeImage() else { return NSImage() }
            return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
        }
        cache = (grid, cap, image)
        return image
    }
}
