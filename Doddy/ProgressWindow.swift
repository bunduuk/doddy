import SwiftUI
import AppKit
import Combine

/// IDM-style window that follows one download live: ring, bar, speed, time left, result.
@MainActor
final class ProgressPanelController: NSObject, NSWindowDelegate {
    static var open: [UUID: ProgressPanelController] = [:]
    static let size = NSSize(width: 520, height: 420)

    private let panel: NSPanel
    private let item: DownloadItem
    private var stateWatch: AnyCancellable?

    static func height(for state: DLState) -> CGFloat {
        switch state {
        case .running, .paused: return 450
        case .queued, .pending: return 300
        case .done: return 300
        case .failed, .cancelled: return 340
        }
    }

    private func resize(animated: Bool) {
        let h = Self.height(for: item.state)
        var f = panel.frame
        let newH = h + (f.height - panel.contentLayoutRect.height)
        guard abs(f.height - newH) > 1 else { return }
        f.origin.y += f.height - newH          // keep the top edge where it is
        f.size.height = newH
        panel.setFrame(f, display: true, animate: animated)
    }

    static func show(_ item: DownloadItem, manager: DownloadManager) {
        if let existing = open[item.id] {
            if existing.panel.isMiniaturized { existing.panel.deminiaturize(nil) }
            existing.panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let c = ProgressPanelController(item: item, manager: manager)
        open[item.id] = c
        // Stack new windows slightly so several downloads do not hide each other.
        let offset = CGFloat(open.count - 1) * 28
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            c.panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - size.width - 24 - offset, y: f.maxY - 24 - offset))
        } else {
            c.panel.center()
        }
        c.panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(item: DownloadItem, manager: DownloadManager) {
        self.item = item
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: ProgressPanelController.size),
                        styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Doddy"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.level = .normal              // behaves like a normal window: other apps can go on top
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ProgressView_(
            item: item,
            onCancel: { manager.cancel(item) },
            onPause: { manager.pause(item) },
            onResume: { manager.resume(item) },
            onRetry: { manager.start(item) },
            onReveal: { manager.reveal(item) },
            onOpenFile: { if let u = item.outputURL { NSWorkspace.shared.open(u) } },
            onPreview: { Preview.open(item) },
            onRefresh: { manager.requestRefresh(item) },
            onClose: { [weak self] in self?.panel.close() }))
        resize(animated: false)
        stateWatch = item.$state.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.resize(animated: true) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        ProgressPanelController.open[item.id] = nil
    }
}

struct ProgressView_: View {
    @ObservedObject var item: DownloadItem
    var onCancel: () -> Void
    var onPause: () -> Void
    var onResume: () -> Void
    var onRetry: () -> Void
    var onReveal: () -> Void
    var onOpenFile: () -> Void
    var onPreview: () -> Void
    var onRefresh: () -> Void
    var onClose: () -> Void

    private var colors: [Color] { Theme.colors(for: item.state) }
    private var known: Double? { item.progress >= 0 ? item.progress : nil }

    private var busy: Bool { item.state == .running || item.state == .paused }

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            ColorfulBackdrop(colors: item.state == .done ? [Theme.blue, Theme.violet] : colors)
                .opacity(item.state == .done ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 14) {
                if item.state == .done { doneHeader } else { header }
                progressBlock

                if item.state == .running, item.method == "Direct file", item.resume.fractions.count > 1 {
                    SegmentBar(fractions: item.resume.fractions)
                }
                if !item.detail.isEmpty && (item.state == .paused || item.state == .queued) {
                    note(item.detail, Theme.orange)
                }
                if busy {
                    SpeedGraphView(samples: item.history).frame(height: 130)
                }
                if busy { stats }
                if item.state == .failed { failure }
                if item.state == .done { success }
                if item.state == .cancelled { note("This download was stopped.", .gray) }

                Spacer(minLength: 0)
                buttons
            }
            .padding(20)
            .padding(.top, 8)

            if item.state == .done { Confetti() }
        }
        .frame(width: ProgressPanelController.size.width)
    }

    // MARK: sections

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: Theme.symbol(for: item.state))
                .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(3).truncationMode(.tail)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Chip(text: item.sourceHost, symbol: "globe", color: Theme.blue)
                    if !item.method.isEmpty { Chip(text: item.method, symbol: "bolt.fill", color: Theme.violet) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var progressBlock: some View {
        if item.state == .running || item.state == .queued || item.state == .paused {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(headline).font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Spacer()
                    if let p = known, item.state != .queued {
                        Text("\(Int(p * 100))%").font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                }
                FunBar(value: item.state == .queued ? nil : (item.state == .done ? 1 : known), colors: colors, height: 10)
            }
        }
    }

    private func note(_ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(color)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
                Text("Download failed").font(.headline)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.detail, forType: .string) }
                    label: { Label("Copy", systemImage: "doc.on.doc") }
                    .glassButton(tint: Theme.red)
            }
            Text(item.detail.isEmpty ? "Something went wrong." : item.detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14, tint: Theme.red)
    }

    private var doneHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark")
                .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(LinearGradient(colors: [Theme.cyan, Theme.blue], startPoint: .topLeading, endPoint: .bottomTrailing)))
            VStack(alignment: .leading, spacing: 5) {
                Text("Download complete").font(.system(size: 20, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Chip(text: item.sourceHost, symbol: "globe", color: Theme.blue)
                    if !item.method.isEmpty { Chip(text: item.method, symbol: "bolt.fill", color: Theme.violet) }
                    if let size = fileSize { Chip(text: size, symbol: "internaldrive", color: Theme.violet) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var fileSize: String? {
        guard let u = item.outputURL, !u.hasDirectoryPath,
              let n = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private var success: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File name").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(item.outputURL?.deletingPathExtension().lastPathComponent ?? item.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Saved in").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(Theme.orange)
                Text(item.outputURL?.deletingLastPathComponent().path ?? item.saveDir.path)
                    .font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 16)
    }

    // MARK: pieces

    private var ring: some View {
        let pct = known.map { "\(Int($0 * 100))%" } ?? "…"
        switch item.state {
        case .done:
            return ProgressRing(value: 1, colors: colors, label: "Done", symbol: "checkmark")
        case .failed:
            return ProgressRing(value: known ?? 0.001, colors: colors, label: "Failed", symbol: "exclamationmark")
        case .cancelled:
            return ProgressRing(value: known ?? 0.001, colors: colors, label: "Stopped", symbol: "xmark")
        case .paused:
            return ProgressRing(value: known ?? 0.001, colors: colors, label: pct, symbol: "pause.fill")
        default:
            return ProgressRing(value: known, colors: colors, label: pct)
        }
    }

    private func mini(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(LinearGradient(colors: [color, color.opacity(0.65)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }

    private var stats: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 10) {
                mini("Speed", item.speed.contains("/s") ? (item.speed.components(separatedBy: "·").first ?? item.speed).trimmingCharacters(in: .whitespaces) : "—",
                     "speedometer", Theme.cyan)
                mini("Time left", eta, "hourglass", Theme.violet)
                mini("Elapsed", formatDuration(Date().timeIntervalSince(item.started)), "clock", Theme.pink)
            }
        }
    }

    private var eta: String {
        guard item.state == .running, phase == nil, let p = known, p > 0.03 else { return "—" }
        let elapsed = Date().timeIntervalSince(item.started)
        let done = p - max(item.baseProgress, 0)        // what this run downloaded (a resume starts part way)
        guard elapsed > 3, done > 0.01 else { return "—" }
        let left = elapsed * (1 - p) / done
        return left < 86_400 ? formatDuration(left) : "—"
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            switch item.state {
            case .running, .queued, .pending:
                Button("Hide") { onClose() }.glassButton()
                if Preview.canPreview(item) {
                    Button { onPreview() } label: { Label("Play so far", systemImage: "play.rectangle") }.glassButton()
                }
                if item.state == .running && item.canPause && phase == nil {
                    Button { onPause() } label: { Label("Pause", systemImage: "pause.fill") }.glassButton()
                }
                Button("Cancel") { onCancel() }.glassButton()
            case .paused:
                Button("Hide") { onClose() }.glassButton()
                if Preview.canPreview(item) {
                    Button { onPreview() } label: { Image(systemName: "play.rectangle") }.glassButton().help("Play so far")
                }
                if item.job.kind != "page" {
                    Button { onRefresh() } label: { Image(systemName: "link") }.glassButton().help("Refresh link: get a new link from the page")
                }
                Button { onResume() } label: { Label("Resume", systemImage: "play.fill") }
                    .glassButton(prominent: true).keyboardShortcut(.defaultAction)
                Button("Cancel") { onCancel() }.glassButton()
            case .done:
                Button { onReveal() } label: { Label("Show in Finder", systemImage: "folder") }.glassButton()
                Button { onOpenFile(); onClose() } label: { Label("Open file", systemImage: "play.fill") }
                    .glassButton(prominent: true).keyboardShortcut(.defaultAction)
                Button("Close") { onClose() }.glassButton()
            case .failed, .cancelled:
                if item.state == .failed && item.job.kind != "page" {
                    Button { onRefresh() } label: { Label("Refresh link", systemImage: "link") }.glassButton()
                }
                Button { onRetry() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .glassButton(prominent: true).keyboardShortcut(.defaultAction)
                Button("Close") { onClose() }.glassButton()
            }
        }
    }

    /// A named step the app is on: "Converting to MP4…", "Merging…", "Joining parts…" and so on. It is the same
    /// text the list shows. A download speed (it contains "/s") is not a step, and neither is "N/A".
    private var phase: String? {
        guard item.state == .running, !item.speed.isEmpty, !item.speed.contains("/s"),
              !item.speed.hasPrefix("N/A"), !item.speed.hasPrefix("Unknown") else { return nil }
        return item.speed
    }

    private var headline: String {
        switch item.state {
        case .queued: return item.retries > 0 && !item.detail.isEmpty ? "Waiting to try again" : "Waiting for its turn"
        case .pending: return "Needs your OK"
        case .paused: return "Paused"
        case .done: return "Finished"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        case .running:
            if let step = phase { return step }                    // converting, merging, joining…
            if item.speed.contains("/s") { return "Downloading" }  // a speed is showing, even if the size is unknown
            return known == nil ? "Getting started" : "Downloading"
        }
    }
}

/// Like IDM's segment strip: one block per connection, filled as that part arrives.
struct SegmentBar: View {
    let fractions: [Double]
    var body: some View {
        let palette = [Theme.blue, Theme.cyan, Theme.violet, Theme.pink, Theme.orange, Theme.yellow]
        HStack(spacing: 3) {
            ForEach(Array(fractions.enumerated()), id: \.offset) { i, f in
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.12))
                        RoundedRectangle(cornerRadius: 3).fill(palette[i % palette.count].gradient)
                            .frame(width: g.size.width * CGFloat(min(max(f, 0), 1)))
                    }
                }
            }
        }
        .frame(height: 9)
    }
}
