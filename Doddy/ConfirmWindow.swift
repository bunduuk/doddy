import SwiftUI
import AppKit

/// IDM/NDM-style "download details" window shown before a download starts.
@MainActor
final class ConfirmPanelController: NSObject, NSWindowDelegate {
    static var open: [UUID: ConfirmPanelController] = [:]

    enum Choice { case start, later, cancel }

    private let panel: NSPanel
    private let item: DownloadItem
    private weak var manager: DownloadManager?
    private var handled = false
    private let initialTitle: String

    static func show(_ item: DownloadItem, manager: DownloadManager) {
        if let existing = open[item.id] {
            existing.panel.makeKeyAndOrderFront(nil)
            return
        }
        let c = ConfirmPanelController(item: item, manager: manager)
        open[item.id] = c
        c.panel.center()
        c.panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(item: DownloadItem, manager: DownloadManager) {
        self.item = item
        self.manager = manager
        self.initialTitle = item.title
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Download details"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let host = NSHostingView(rootView: ConfirmView(
            item: item,
            onStart: { [weak self] in self?.finish(.start) },
            onLater: { [weak self] in self?.finish(.later) },
            onCancel: { [weak self] in self?.finish(.cancel) }))
        panel.contentView = host
        // Keep the file name from taking focus (and from starting selected) instead of un-focusing it afterwards.
        panel.autorecalculatesKeyViewLoop = false
        panel.initialFirstResponder = host
        if let size = panel.contentView?.fittingSize, size.height > 100 { panel.setContentSize(size) }
    }

    private func finish(_ c: Choice) {
        handled = true
        ConfirmPanelController.open[item.id] = nil
        if c != .cancel {
            let typed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty && typed != initialTitle { item.job.customName = true }   // keep the user's own name
        }
        panel.close()
        switch c {
        case .start: manager?.confirm(item, startNow: true)
        case .later: manager?.confirm(item, startNow: false)
        case .cancel: manager?.remove(item)
        }
    }

    // Closing the window with the red button counts as Cancel, like IDM.
    func windowWillClose(_ notification: Notification) {
        guard !handled else { return }
        handled = true
        ConfirmPanelController.open[item.id] = nil
        manager?.remove(item)
    }
}

struct ConfirmView: View {
    @ObservedObject var item: DownloadItem
    var onStart: () -> Void
    var onLater: () -> Void
    var onCancel: () -> Void
    @AppStorage("askBeforeDownload") private var ask = true

    private func chip(_ text: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.18)))
        .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(LinearGradient(colors: [Theme.blue, Theme.violet, Theme.pink],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready to download").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(item.sourceHost).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.top, 14)

            HStack(spacing: 8) {
                chip(item.kindDescription, "film", Theme.cyan)
                if let size = item.sizeText { chip(size, "internaldrive", Theme.violet) }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("File name").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("File name", text: $item.title, axis: .vertical)
                    .autocorrectionDisabled()
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.08)))
                Divider()
                Text("Save to").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.orange)
                    Text(item.saveDir.path).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Change…") { pickFolder() }.glassButton()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: 16)

            HStack {
                Text("Don't ask again")
                Spacer()
                Toggle("", isOn: Binding(get: { !ask }, set: { ask = !$0 }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .padding(.horizontal, 4)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel).glassButton().keyboardShortcut(.cancelAction)
                Button("Later", action: onLater).glassButton()
                Button { onStart() } label: { Label("Download", systemImage: "arrow.down") }
                    .glassButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
        .frame(width: 480)
        .background(ColorfulBackdrop(colors: [Theme.blue, Theme.pink]))
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = item.saveDir
        p.prompt = "Choose"
        if p.runModal() == .OK, let u = p.url { item.saveDir = u }
    }
}
