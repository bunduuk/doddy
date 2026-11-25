import SwiftUI
import AppKit

// MARK: - Colours

enum Theme {
    static let blue   = Color(red: 0.30, green: 0.55, blue: 0.92)
    static let cyan   = Color(red: 0.42, green: 0.86, blue: 0.98)
    static let violet = Color(red: 0.66, green: 0.26, blue: 0.76)
    static let pink   = Color(red: 0.86, green: 0.36, blue: 0.56)
    static let orange = Color(red: 0.96, green: 0.55, blue: 0.30)
    static let yellow = Color(red: 0.98, green: 0.84, blue: 0.35)
    static let navy   = Color(red: 0.16, green: 0.20, blue: 0.42)

    /// The signature look: warm orange fading through pink into purple.
    static let brand = LinearGradient(colors: [orange, pink, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let red    = Color(red: 1.00, green: 0.30, blue: 0.35)
    static let green  = Color(red: 0.30, green: 0.85, blue: 0.40)

    static func colors(for state: DLState) -> [Color] {
        switch state {
        case .running: return [blue, violet, pink, orange]
        case .queued, .pending: return [blue, violet]
        case .paused: return [orange, yellow]
        case .done: return [cyan, blue]
        case .failed: return [pink, red]
        case .cancelled: return [Color.gray, Color.gray.opacity(0.7)]
        }
    }


    static func symbol(for state: DLState) -> String {
        switch state {
        case .running: return "arrow.down"
        case .queued: return "clock"
        case .pending: return "slider.horizontal.3"
        case .paused: return "pause.fill"
        case .done: return "checkmark"
        case .failed: return "exclamationmark"
        case .cancelled: return "xmark"
        }
    }
}

// MARK: - Liquid Glass (macOS 26) with a material look on older systems

struct GlassCard: ViewModifier {
    var radius: CGFloat = 16
    var tint: Color? = nil

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(
                tint.map { Glass.regular.tint($0.opacity(0.22)) } ?? Glass.regular,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            classic(content)
        }
        #else
        classic(content)
        #endif
    }

    private func classic(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder((tint ?? Color.white).opacity(0.28), lineWidth: 1))
    }
}

/// Clear, tinted capsule buttons that read well on glass and on dark backgrounds.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color? = nil
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let t = tint ?? Theme.violet
        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(
                Capsule().fill(prominent
                    ? (tint == nil ? AnyShapeStyle(Theme.brand)
                                   : AnyShapeStyle(LinearGradient(colors: [t, t.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    : AnyShapeStyle(t.opacity(configuration.isPressed ? 0.32 : 0.18)))
            )
            .overlay(Capsule().strokeBorder(prominent ? Color.white.opacity(0.25) : t.opacity(0.55), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.45)
    }
}

struct GlassButton: ViewModifier {
    var prominent = false
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content.buttonStyle(PillButtonStyle(prominent: prominent, tint: tint))
    }
}

extension View {
    func glassCard(radius: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(GlassCard(radius: radius, tint: tint))
    }
    func glassButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        modifier(GlassButton(prominent: prominent, tint: tint))
    }
}

// MARK: - Backdrop

/// Soft coloured glow behind the content, so the glass has something to refract.
struct ColorfulBackdrop: View {
    var colors: [Color]
    /// The coloured glow behind windows was removed on purpose; kept as a no-op so call sites stay simple.
    var body: some View { Color.clear.allowsHitTesting(false) }
}

// MARK: - Progress bits

struct FunBar: View {
    var value: Double?          // nil = unknown length
    var colors: [Color]
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if let v = value {
                    let w = max(height, g.size.width * CGFloat(min(max(v, 0), 1)))
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: w)
                        .overlay(Shimmer().clipShape(Capsule()))
                        .animation(.easeOut(duration: 0.4), value: v)
                } else {
                    Bouncer(colors: colors, width: g.size.width, height: height)
                }
            }
        }
        .frame(height: height)
    }
}

/// Whether Doddy is the frontmost app. Decorative animations pause when it is not, so a hidden or
/// closed window never keeps the display cycle busy (it showed up as steady CPU use at idle).
@MainActor
final class AppActivity: ObservableObject {
    static let shared = AppActivity()
    @Published var active: Bool
    private init() {
        active = NSApplication.shared.isActive
        let c = NotificationCenter.default
        c.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.active = true }
        }
        c.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.active = false }
        }
    }
}

struct Shimmer: View {
    @ObservedObject private var act = AppActivity.shared
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !act.active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: 1.6) / 1.6
            GeometryReader { g in
                LinearGradient(colors: [.clear, Color.white.opacity(0.5), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: g.size.width * 0.35)
                    .offset(x: g.size.width * 1.35 * CGFloat(phase) - g.size.width * 0.35)
            }
        }
        .allowsHitTesting(false)
    }
}

struct Bouncer: View {
    @ObservedObject private var act = AppActivity.shared
    var colors: [Color]
    var width: CGFloat
    var height: CGFloat
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !act.active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let seg = width * 0.3
            let x = (width - seg) * CGFloat(0.5 + 0.5 * sin(t * 2.4))
            Capsule()
                .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                .frame(width: seg, height: height)
                .offset(x: x)
        }
    }
}

struct ProgressRing: View {
    @ObservedObject private var act = AppActivity.shared
    var value: Double?
    var colors: [Color]
    var label: String
    var symbol: String? = nil
    var line: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: line)
            if let v = value {
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(v, 0.001), 1)))
                    .stroke(AngularGradient(colors: colors + [colors.first ?? .blue], center: .center),
                            style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: v)
            } else {
                TimelineView(.animation(minimumInterval: nil, paused: !act.active)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom),
                                style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
                }
            }
            VStack(spacing: 2) {
                if let s = symbol {
                    Image(systemName: s).font(.system(size: 22, weight: .bold))
                        .foregroundStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                }
                Text(label).font(.system(size: symbol == nil ? 24 : 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .padding(line / 2)
    }
}

struct Chip: View {
    let text: String
    var symbol: String? = nil
    var color: Color = Theme.blue
    var body: some View {
        HStack(spacing: 4) {
            if let s = symbol { Image(systemName: s) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.18), in: Capsule())
        .foregroundStyle(color)
    }
}


struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    var color: Color = Theme.blue
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(LinearGradient(colors: [color, color.opacity(0.65)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .padding(14)
        .glassCard(radius: 16, tint: color)
    }
}

/// A little party when a download finishes.
struct Confetti: View {
    @State private var go = false
    private let pieces: [(x: Double, fall: Double, spin: Double, color: Color, size: Double)] = (0..<30).map { _ in
        (Double.random(in: -1...1), Double.random(in: 0.5...1.0), Double.random(in: 0...360),
         [Theme.blue, Theme.pink, Theme.yellow, Theme.cyan, Theme.violet, Theme.orange].randomElement() ?? Theme.blue,
         Double.random(in: 5...9))
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                ForEach(0..<pieces.count, id: \.self) { i in
                    let p = pieces[i]
                    RoundedRectangle(cornerRadius: 2)
                        .fill(p.color)
                        .frame(width: p.size, height: p.size * 1.6)
                        .rotationEffect(.degrees(go ? p.spin + 540 : p.spin))
                        .offset(x: go ? p.x * g.size.width * 0.5 : 0, y: go ? g.size.height * p.fall : -20)
                        .opacity(go ? 0 : 1)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeOut(duration: 1.8)) { go = true } }
    }
}

// MARK: - Small helpers

func formatDuration(_ s: TimeInterval) -> String {
    let t = Int(max(0, s))
    let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

// MARK: - The line under the toolbar

/// Replaces the plain hairline with a soft rainbow glow that slowly drifts.
struct GradientLine: View {
    @ObservedObject private var act = AppActivity.shared
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !act.active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let shift = CGFloat((t / 6).truncatingRemainder(dividingBy: 1))
            ZStack {
                LinearGradient(colors: [Theme.cyan, Theme.blue, Theme.violet, Theme.pink, Theme.orange, Theme.cyan],
                               startPoint: UnitPoint(x: shift - 1, y: 0), endPoint: UnitPoint(x: shift + 1, y: 0))
                    .frame(height: 2)
                    .clipShape(Capsule())
            }
            .frame(height: 6)
        }
        .allowsHitTesting(false)
    }
}

/// Switches off the system's grey separator under the title bar, so GradientLine can take its place.
struct WindowTweaks: NSViewRepresentable {
    /// Turns off every scroll bar in the window; scrolling itself keeps working.
    static func hideScrollers(in view: NSView?) {
        guard let view else { return }
        if let sv = view as? NSScrollView {
            if sv.hasVerticalScroller { sv.hasVerticalScroller = false }
            if sv.hasHorizontalScroller { sv.hasHorizontalScroller = false }
        }
        for sub in view.subviews { hideScrollers(in: sub) }
    }

    final class Coordinator {
        var timer: Timer?
        deinit { timer?.invalidate() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            v.window?.titlebarSeparatorStyle = .none
            Self.hideScrollers(in: v.window?.contentView)
        }
        context.coordinator.timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak v] _ in
            guard let w = v?.window, w.isVisible else { return }
            Self.hideScrollers(in: v?.window?.contentView)
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            v.window?.titlebarSeparatorStyle = .none
            Self.hideScrollers(in: v.window?.contentView)
        }
    }
}
