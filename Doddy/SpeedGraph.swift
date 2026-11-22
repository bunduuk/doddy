import SwiftUI

/// Live download-speed graph: a smooth gradient area (orange/pink/purple over a blue layer) set inside
/// a card with some breathing room. Hover over it to see dashed guide lines and a pill with the speed.

private func speedText(_ v: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(v, 0)), countStyle: .file) + "/s"
}

struct SpeedGraphView: View {
    let samples: [Double]
    @State private var hoverX: CGFloat? = nil
    @State private var hoverStamp = 0

    private static let navy = Color(red: 0.16, green: 0.20, blue: 0.42)
    private let side: CGFloat = 0       // space left and right of the plot
    private let lower: CGFloat = 0      // space under the plot

    private static func curve(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard pts.count > 1 else { return p }
        p.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            p.addCurve(to: p2, control1: c1, control2: c2)
        }
        return p
    }

    private static func area(_ pts: [CGPoint], baseline: CGFloat) -> Path {
        var p = curve(pts)
        guard let first = pts.first, let last = pts.last else { return p }
        p.addLine(to: CGPoint(x: last.x, y: baseline))
        p.addLine(to: CGPoint(x: first.x, y: baseline))
        p.closeSubpath()
        return p
    }

    /// A slower, averaged copy of the samples, drawn behind as the blue layer.
    private static func averaged(_ v: [Double]) -> [Double] {
        v.indices.map { i in
            let lo = max(0, i - 6)
            let hi = min(v.count - 1, i + 6)
            let slice = v[lo...hi]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    private static func points(_ vals: [Double], width: CGFloat, top: CGFloat, bottom: CGFloat, peak: Double) -> [CGPoint] {
        let n = vals.count
        return vals.enumerated().map { i, v in
            let x = n > 1 ? width * CGFloat(i) / CGFloat(n - 1) : 0
            let y = top + (bottom - top) * (1 - CGFloat(v / peak))
            return CGPoint(x: x, y: min(max(y, top), bottom))
        }
    }

    var body: some View {
        GeometryReader { g in
            let pw = max(g.size.width - side * 2, 1)       // plot width
            let ph = max(g.size.height - lower, 1)         // plot height
            let top: CGFloat = 66
            let peak = max(samples.max() ?? 1, 1)
            let count = samples.count

            let pts = Self.points(samples, width: pw, top: top, bottom: ph, peak: peak)
            let backPts = Self.points(Self.averaged(samples), width: pw, top: top, bottom: ph, peak: peak)

            let front = LinearGradient(colors: [Color(red: 0.96, green: 0.55, blue: 0.30),
                                                Color(red: 0.86, green: 0.36, blue: 0.56),
                                                Color(red: 0.66, green: 0.26, blue: 0.76)],
                                       startPoint: .top, endPoint: .bottom)
            let back = LinearGradient(colors: [Color(red: 0.42, green: 0.86, blue: 0.98),
                                               Color(red: 0.30, green: 0.52, blue: 0.90)],
                                      startPoint: .top, endPoint: .bottom)

            // a marker only while the pointer is over the graph
            let hoverIndex: Int? = {
                guard let hx = hoverX, count > 1 else { return nil }
                let i = Int(((hx - side) / pw * CGFloat(count - 1)).rounded())
                return min(max(i, 0), count - 1)
            }()

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.07))

                if count > 1 {
                    // the coloured areas, with rounded corners, edge to edge
                    ZStack(alignment: .topLeading) {
                        Self.area(backPts, baseline: ph).fill(back).opacity(0.9)
                        Self.area(pts, baseline: ph).fill(front).opacity(0.92)
                    }
                    .frame(width: pw, height: ph, alignment: .topLeading)
                    .offset(x: side)

                    if let i = hoverIndex {
                        let p = pts[i]
                        ZStack(alignment: .topLeading) {
                            Path { path in
                                path.move(to: p)
                                path.addLine(to: CGPoint(x: p.x, y: ph))
                            }
                            .stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

                            Circle().fill(Self.navy).frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                                .position(p)

                            Text(speedText(samples[i]))
                                .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(Self.navy))
                                .position(x: min(max(p.x, 36), pw - 36), y: max(p.y - 17, 54))
                        }
                        .frame(width: pw, height: ph, alignment: .topLeading)
                        .offset(x: side)
                        .allowsHitTesting(false)
                    }
                } else {
                    Text("Measuring speed…").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let now = samples.last, count > 1 {
                    HStack(alignment: .firstTextBaseline) {
                        Text(speedText(now))
                            .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                        Spacer()
                        Text("Peak " + speedText(peak))
                            .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.top, 10)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    hoverX = loc.x
                    hoverStamp += 1
                    let stamp = hoverStamp
                    // If the "pointer left" event never arrives (after a click or a window drag), let go by itself.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if hoverStamp == stamp { hoverX = nil }
                    }
                case .ended:
                    hoverX = nil
                }
            }
            .onHover { inside in if !inside { hoverX = nil } }
            .onDisappear { hoverX = nil }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
