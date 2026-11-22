import SwiftUI
import AppKit
import ServiceManagement

enum Page: Hashable { case all, active, done, failed, stats, setup }

struct ContentView: View {
    @EnvironmentObject var manager: DownloadManager
    @State private var page: Page = .all
    @State private var tick = 0
    @State private var query = ""
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State private var showTour = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private func count(_ p: Page) -> Int { base(p).count }

    private func filtered(_ p: Page) -> [DownloadItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = base(p)
        return q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) || $0.sourceHost.lowercased().contains(q) }
    }

    private func base(_ p: Page) -> [DownloadItem] {
        switch p {
        case .all, .setup, .stats: return manager.items
        case .active: return manager.items.filter { $0.state == .running || $0.state == .paused || $0.state == .queued || $0.state == .pending }
        case .done: return manager.items.filter { $0.state == .done }
        case .failed: return manager.items.filter { $0.state == .failed || $0.state == .cancelled }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section("Library") {
                    side("All", "list.bullet", Theme.blue).badge(count(.all)).tag(Page.all)
                    side("Active", "arrow.down", Theme.cyan).badge(count(.active)).tag(Page.active)
                    side("Finished", "checkmark", Theme.violet).badge(count(.done)).tag(Page.done)
                    side("Failed", "exclamationmark", Theme.pink).badge(count(.failed)).tag(Page.failed)
                }
                Section("Doddy") {
                    side("Stats", "chart.bar.fill", Theme.orange).tag(Page.stats)
                    side("Setup", "gearshape.fill", Theme.violet).tag(Page.setup)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail
                .background(ColorfulBackdrop(colors: [Theme.blue, Theme.orange]).opacity(0.55))
                .overlay(alignment: .top) { GradientLine() }
                .background(WindowTweaks())
        }
        .onReceive(timer) { _ in if manager.activeCount > 0 { tick += 1 } }   // idle: no redraw every second
        .onAppear { if !onboardingDone { showTour = true } }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("doddyShowTour"))) { _ in showTour = true }
        .sheet(isPresented: $showTour) {
            OnboardingView { onboardingDone = true; showTour = false }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search downloads")
        .onDrop(of: [.url, .plainText], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            let mgr = manager
            if p.hasItemConformingToTypeIdentifier("public.url") {
                _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                    if let s = (obj as? NSURL)?.absoluteString { Task { @MainActor in mgr.addLink(s) } }
                }
                return true
            }
            if p.canLoadObject(ofClass: NSString.self) {
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    if let s = obj as? NSString { Task { @MainActor in mgr.addLink(s as String) } }
                }
                return true
            }
            return false
        }
        .toolbar {
            ToolbarItemGroup {
                Button { manager.askForLink() } label: { Label("Add link", systemImage: "link.badge.plus") }
                    .help("Paste a link, or drop one here")
                Button { NSWorkspace.shared.open(Paths.downloads) } label: { Label("Open folder", systemImage: "folder") }
                Menu {
                    Button("Clear finished") { manager.clearFinished() }
                        .disabled(count(.done) + count(.failed) == 0)
                    Button("Clear list") { confirmClearAll(deleteFiles: false) }
                    Divider()
                    Button("Clear list and trash files…") { confirmClearAll(deleteFiles: true) }
                } label: { Label("Clear", systemImage: "trash") }
                .disabled(manager.items.isEmpty)
            }
        }
        .navigationTitle("Doddy")
        .scrollIndicators(.hidden)
        .task { await ToolManager.shared.installMissingOnce() }
    }

    private func side(_ title: String, _ symbol: String, _ color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(LinearGradient(colors: [color, color.opacity(0.65)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
        }
    }

    private func confirmClearAll(deleteFiles: Bool) {
        let a = NSAlert()
        a.messageText = deleteFiles ? "Clear the list and trash the files?"
                                    : "Clear the list?"
        var info = deleteFiles ? "Finished files go to the Trash. You can restore them from there. " : "Your files stay where they are. "
        if manager.activeCount > 0 { info += "Active downloads will be cancelled." }
        a.informativeText = info
        a.addButton(withTitle: deleteFiles ? "Move to Trash" : "Clear list")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { manager.clearAll(deleteFiles: deleteFiles) }
    }

    @ViewBuilder private var detail: some View {
        if page == .stats {
            StatsView()
        } else if page == .setup {
            GeometryReader { g in
                ScrollView {
                    SetupView()
                        .frame(width: min(600, max(g.size.width - 48, 320)))
                        .padding(24)
                        .frame(width: g.size.width)
                }
                .scrollIndicators(.hidden)
            }
        } else if filtered(page).isEmpty {
            VStack(spacing: 12) {
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(LinearGradient(colors: [Theme.blue, Theme.violet, Theme.pink, Theme.orange],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                        .offset(y: CGFloat(sin(t * 2)) * 5)
                }
                Text(page == .all ? "No downloads yet" : "Nothing here")
                    .font(.title2.weight(.semibold))
                Text("Download a file in Chrome, or hover over a video and press Download.")
                    .foregroundStyle(.secondary)
                if page == .all {
                    Button("Open Setup") { page = .setup }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filtered(page)) { item in DownloadRow(item: item) }
                }
                .padding(16)
            }
        }
    }
}

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    @EnvironmentObject var manager: DownloadManager

    var body: some View {
        HStack(spacing: 12) {
            if item.state == .done, let u = item.outputURL, !(u.hasDirectoryPath) {
                Thumb(url: u)
            } else {
                ZStack {
                    Circle().fill(LinearGradient(colors: Theme.colors(for: item.state),
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: Theme.symbol(for: item.state))
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.headline).lineLimit(1).textSelection(.enabled)
                if item.state == .running {
                    FunBar(value: item.progress >= 0 ? item.progress : nil,
                           colors: Theme.colors(for: item.state), height: 8)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(item.state == .failed ? Theme.red : Color.secondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }

            Spacer()

            HStack(spacing: 4) {
                switch item.state {
                case .pending:
                    Button { ConfirmPanelController.show(item, manager: manager) } label: { Image(systemName: "slider.horizontal.3") }
                        .help("Details")
                case .queued:
                    Button { manager.start(item, force: true) } label: { Image(systemName: "play.circle") }
                        .help("Start")
                case .running:
                    if item.canPause {
                        Button { manager.pause(item) } label: { Image(systemName: "pause.circle") }
                            .help("Pause")
                    }
                    Button { manager.cancel(item) } label: { Image(systemName: "xmark.circle") }
                        .help("Cancel")
                case .paused:
                    Button { manager.resume(item) } label: { Image(systemName: "play.circle") }
                        .help("Resume")
                    if item.job.kind != "page" {
                        Button { manager.requestRefresh(item) } label: { Image(systemName: "link.circle") }
                            .help("Get a fresh link and continue")
                    }
                    Button { manager.cancel(item) } label: { Image(systemName: "xmark.circle") }
                        .help("Cancel")
                case .done:
                    Button { manager.reveal(item) } label: { Image(systemName: "magnifyingglass.circle") }
                        .help("Show in Finder")
                case .failed, .cancelled:
                    Button { manager.start(item) } label: { Image(systemName: "arrow.clockwise.circle") }
                        .help("Retry")
                    if item.job.kind != "page" && item.state == .failed {
                        Button { manager.requestRefresh(item) } label: { Image(systemName: "link.circle") }
                            .help("Get a fresh link and continue")
                    }
                }
                Menu {
                    Button("Remove") { manager.remove(item) }
                    if item.state == .done {
                        Button("Remove and trash file") { manager.removeWithFile(item) }
                    }
                } label: { Image(systemName: "trash") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Remove")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 18))
        }
        .padding(12)
        .glassCard(radius: 16, tint: item.state == .failed ? Theme.red : nil)
    }

    private var subtitle: String {
        switch item.state {
        case .running:
            let pct = item.progress >= 0 ? "\(Int(item.progress * 100))%" : "Working…"
            return [item.method, pct, item.speed].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        case .failed: return item.detail
        case .paused:
            if !item.detail.isEmpty { return item.detail }
            return item.progress >= 0 ? "Paused at \(Int(item.progress * 100))%" : "Paused"
        case .done: return item.outputURL?.lastPathComponent ?? "Finished"
        case .queued:
            if !item.detail.isEmpty { return item.detail }
            if item.waiting, manager.isHeld, let h = manager.holdUntil {
                return "Scheduled: starts at " + h.formatted(date: .omitted, time: .shortened)
            }
            return item.waiting ? "Waiting for a free slot…" : item.state.label
        default: return item.state.label
        }
    }

    private var icon: String {
        switch item.state {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .paused: return "pause.circle.fill"
        default: return "arrow.down.circle.fill"
        }
    }

    private var color: Color {
        switch item.state {
        case .paused: return Theme.orange
        case .done: return Theme.blue
        case .failed: return .red
        case .cancelled: return .gray
        default: return Theme.blue
        }
    }
}

struct MenuRow: View {
    @ObservedObject var item: DownloadItem
    @EnvironmentObject var manager: DownloadManager
    @State private var hover = false
    private var finished: Bool { item.state == .done || item.state == .failed || item.state == .cancelled }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(item.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(item.speed.isEmpty ? item.state.label : item.speed)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if finished {
                    Button { withAnimation { item.hiddenInMenu = true; manager.objectWillChange.send(); manager.saveHistory(force: true) } } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(hover ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear from this menu (it stays in Doddy)")
                    .onHover { hover = $0 }
                }
            }
            FunBar(value: item.progress >= 0 ? item.progress : nil, colors: Theme.colors(for: item.state), height: 5)
        }
        .contentShape(Rectangle())
        .onTapGesture { ProgressPanelController.show(item, manager: manager) }
        .help("Show this download’s window")
    }
}

struct MenuButton: View {
    let title: String
    let symbol: String
    var color: Color = Theme.blue
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(LinearGradient(colors: [color, color.opacity(0.65)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.10 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct MenuView: View {
    @EnvironmentObject var manager: DownloadManager
    @Environment(\.openWindow) private var openWindow

    private var current: [DownloadItem] {
        Array(manager.items.filter { $0.state != .pending && !$0.hiddenInMenu }.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Doddy").font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(manager.activeCount > 0 ? "\(manager.activeCount) downloading" : "All quiet")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !current.isEmpty {
                VStack(spacing: 10) {
                    ForEach(current) { MenuRow(item: $0) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(radius: 14)
            }

            VStack(spacing: 2) {
                if manager.items.contains(where: { ($0.state == .done || $0.state == .failed || $0.state == .cancelled) && !$0.hiddenInMenu }) {
                    MenuButton(title: "Clear finished", symbol: "xmark", color: Theme.violet) {
                        withAnimation {
                            for i in manager.items where i.state == .done || i.state == .failed || i.state == .cancelled { i.hiddenInMenu = true }
                            manager.objectWillChange.send()
                            manager.saveHistory(force: true)
                        }
                    }
                }
                MenuButton(title: "Open Doddy", symbol: "arrow.down.circle.fill", color: Theme.blue) {
                    DockMode.show()
                    openWindow(id: "main")
                }
                MenuButton(title: "Add link", symbol: "link", color: Theme.cyan) {
                    manager.askForLink()
                }
                MenuButton(title: "Open folder", symbol: "folder.fill", color: Theme.orange) {
                    NSWorkspace.shared.open(Paths.downloads)
                }
            }
            Divider()
            MenuButton(title: "Quit Doddy", symbol: "power", color: Theme.pink) { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 290)
    }
}

/// Setup checklist: shown on the empty screen and in Settings (⌘,).
struct SetupView: View {
    @ObservedObject var tools = ToolManager.shared
    @AppStorage("askBeforeDownload") private var askBeforeDownload = true
    @State private var tick = 0
    @AppStorage("saveDir") private var saveDirStored = ""
    @AppStorage("showProgressWindow") private var showProgressWindow = true
    @AppStorage("maxParallel") private var maxParallel = 3
    @AppStorage("speedLimitKB") private var speedLimitKB = 0
    @AppStorage("scheduleEnabled") private var scheduleEnabled = false
    @AppStorage("scheduleMinutes") private var scheduleMinutes = 120
    @AppStorage("afterQueue") private var afterQueue = "none"
    @AppStorage("nameTemplate") private var nameTemplate = "{title}"
    @AppStorage("subtitlesOn") private var subtitlesOn = false
    @AppStorage("subtitleLangs") private var subtitleLangs = "en"
    @AppStorage("translateSubs") private var translateSubs = false
    @AppStorage("cleanNames") private var cleanNames = false
    @AppStorage("finishSound") private var finishSound = true
    @AppStorage("autoRetry") private var autoRetry = 2
    @AppStorage("chromeCookies") private var chromeCookies = false
    @AppStorage("fastYouTube") private var fastYouTube = true
    @AppStorage("updateRepo") private var updateRepo = ""
    @AppStorage("watchClipboard") private var watchClipboard = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("sortFolders") private var sortFolders = "none"
    @AppStorage("convertAfter") private var convertAfter = "none"
    @AppStorage("convertDeleteOriginal") private var convertDeleteOriginal = false

    private var scheduleDate: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: scheduleMinutes / 60, minute: scheduleMinutes % 60,
                                         second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                scheduleMinutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }

    private var saveDirPath: String { saveDirStored.isEmpty ? Paths.downloads.path : saveDirStored }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: saveDirPath)
        if panel.runModal() == .OK, let url = panel.url { saveDirStored = url.path }
    }

    private enum Tab: String, CaseIterable, Identifiable {
        case status = "Status", downloads = "Downloads", files = "Files", sites = "Sites & subtitles", app = "App"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .status: return "checkmark.seal"
            case .downloads: return "arrow.down.circle"
            case .files: return "folder"
            case .sites: return "globe"
            case .app: return "gearshape"
            }
        }
        var color: Color {
            switch self {
            case .status: return Theme.violet
            case .downloads: return Theme.blue
            case .files: return Theme.orange
            case .sites: return Theme.violet
            case .app: return Theme.pink
            }
        }
    }
    @State private var tab: Tab = .status

    // MARK: building blocks

    private func section<C: View>(_ title: String, _ symbol: String, _ color: Color, subtitle: String? = nil,
                                  @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(LinearGradient(colors: [color, color.opacity(0.65)],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
                        if let subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Rectangle()
                    .fill(LinearGradient(colors: [color.opacity(0.7), color.opacity(0.0)], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 2).clipShape(Capsule())
            }
            .padding(.bottom, 2)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 18)
    }

    private func flag(_ title: String, _ hint: String? = nil, _ value: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let hint { Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private func pick<T: Hashable>(_ title: String, _ value: Binding<T>, _ options: [(String, T)]) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Picker("", selection: value) {
                ForEach(options.indices, id: \.self) { Text(options[$0].0).tag(options[$0].1) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Tab.allCases) { t in
                    Button { withAnimation(.snappy) { tab = t } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: t.symbol)
                            Text(t.rawValue)
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundStyle(tab == t ? Color.white : Color.primary)
                        .background(Capsule().fill(tab == t
                            ? AnyShapeStyle(LinearGradient(colors: [t.color, t.color.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color.primary.opacity(0.08))))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: pages

    private var statusPage: some View {
        VStack(spacing: 14) {
            section("Your Mac", "checkmark.seal", Theme.violet, subtitle: "Is everything ready?") {
                row(ok: !Installer.installedBrowsers().isEmpty, text: "Chrome found")
                Divider()
                row(ok: Installer.helperRegistered(), text: "Browser helper connected")
            }
            section("Tools", "wrench.and.screwdriver", Theme.cyan, subtitle: "Helpers Doddy needs") {
                toolRow("yt-dlp", path: tools.ytdlpPath, note: "YouTube & 1000+ sites", canUpdate: true)
                Divider()
                toolRow("ffmpeg", path: tools.ffmpegPath, note: "streams, .ts to .mp4, merging", canUpdate: false)
                Divider()
                toolRow("deno", path: tools.denoPath, note: "needed for YouTube", canUpdate: false)
                if !tools.message.isEmpty {
                    Text(tools.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button { Task { await tools.checkVersions() }; tick += 1 } label: {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                    .glassButton()
                }
            }
            section("Chrome extension", "puzzlepiece.extension", Theme.violet, subtitle: "Adds the Download button") {
                Text("Open chrome://extensions, turn on Developer mode, press Load unpacked and choose the extension folder.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { Installer.revealExtensionFolder() } label: { Label("Show folder", systemImage: "folder") }.glassButton()
                    Button { Installer.openChromeExtensionsPage() } label: { Label("Open Chrome extensions", systemImage: "arrow.up.right.square") }.glassButton(prominent: true)
                }
            }
        }
    }

    private var downloadsPage: some View {
        VStack(spacing: 14) {
            section("While downloading", "arrow.down.circle", Theme.blue, subtitle: "Windows, speed and limits") {
                flag("Ask before each download", nil, $askBeforeDownload)
                Divider()
                flag("Show progress window", nil, $showProgressWindow)
                Divider()
                HStack {
                    Text("Simultaneous downloads")
                    Spacer()
                    Stepper("\(maxParallel)", value: $maxParallel, in: 1...8).fixedSize()
                }
                Divider()
                flag("Fast YouTube mode", "Uses many connections at once. Falls back by itself if it can't.", $fastYouTube)
                Divider()
                pick("Speed limit", $speedLimitKB, [("No limit", 0), ("500 KB/s", 512), ("1 MB/s", 1024), ("2 MB/s", 2048),
                                                    ("5 MB/s", 5120), ("10 MB/s", 10240), ("20 MB/s", 20480)])
            }
            section("Timing", "clock", Theme.orange, subtitle: "Schedule and finish action") {
                HStack {
                    Text("Start downloads at")
                    Spacer()
                    if scheduleEnabled {
                        DatePicker("", selection: scheduleDate, displayedComponents: .hourAndMinute)
                            .labelsHidden().fixedSize()
                    }
                    Toggle("", isOn: $scheduleEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider()
                pick("When the queue ends", $afterQueue, [("Do nothing", "none"), ("Quit Doddy", "quit"), ("Sleep the Mac", "sleep")])
            }
            section("If something goes wrong", "arrow.triangle.2.circlepath", Theme.pink, subtitle: "Retries and sound") {
                pick("Retry failures", $autoRetry, [("Never", 0), ("Once", 1), ("Up to 2 times", 2), ("Up to 4 times", 4)])
                Divider()
                flag("Play a sound when done", nil, $finishSound)
            }
            section("Links", "link", Theme.cyan, subtitle: "Copied links") {
                flag("Offer to download copied links", nil, $watchClipboard)
            }
        }
    }

    private var filesPage: some View {
        VStack(spacing: 14) {
            section("Where files go", "folder", Theme.orange, subtitle: "Folder and sorting") {
                HStack(spacing: 8) {
                    Text(saveDirPath).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button { chooseFolder() } label: { Label("Change…", systemImage: "folder.badge.gearshape") }.glassButton()
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: saveDirPath)) } label: { Label("Open", systemImage: "arrow.up.forward.app") }.glassButton()
                }
                Divider()
                pick("Sort into folders", $sortFolders, [("Don't sort", "none"), ("By website", "site"), ("By type", "type")])
            }
            section("File names", "textformat", Theme.blue, subtitle: "Naming") {
                HStack {
                    Text("Name")
                    TextField("{title}", text: $nameTemplate).textFieldStyle(.roundedBorder)
                }
                Text("Tags: {title} {site} {date} {quality}. Example: {site} - {title}")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                flag("Clean names", "Removes tags like [1080p] and (Official Video).", $cleanNames)
            }
            section("Convert", "arrow.triangle.swap", Theme.violet, subtitle: "After downloading") {
                pick("When finished", $convertAfter, [("Keep original", "none"), ("To MP4", "mp4"), ("To MP3", "mp3"), ("To M4A", "m4a")])
                if convertAfter != "none" {
                    Divider()
                    flag("Delete the original", nil, $convertDeleteOriginal)
                }
            }
            section("Housekeeping", "sparkles", Theme.pink, subtitle: "Clean up") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Deletes leftovers from cancelled downloads.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { Maintenance.tidy(manager: DownloadManager.shared) } label: { Label("Clean up leftovers…", systemImage: "sparkles") }.glassButton(tint: Theme.pink)
                }
            }
        }
    }

    private var sitesPage: some View {
        VStack(spacing: 14) {
            section("Subtitles", "captions.bubble", Theme.cyan, subtitle: "Languages and translation") {
                HStack {
                    Text("Subtitles")
                    Spacer()
                    TextField("en", text: $subtitleLangs).textFieldStyle(.roundedBorder).frame(width: 80)
                        .disabled(!subtitlesOn).help("Language codes, separated by commas, such as en,es")
                    Toggle("", isOn: $subtitlesOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider()
                flag("Translate to English", "Runs on your Mac. Needs macOS 15+.", $translateSubs).disabled(!subtitlesOn)
            }
            section("Site rules", "slider.horizontal.3", Theme.violet, subtitle: "Quality, folder and logins per website") {
                SiteRulesView()
            }
        }
    }

    private var appPage: some View {
        VStack(spacing: 14) {
            section("General", "gearshape", Theme.pink, subtitle: "Start-up and tour") {
                flag("Open at login", nil, $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Divider()
                Button { NotificationCenter.default.post(name: Notification.Name("doddyShowTour"), object: nil) } label: { Label("Replay welcome tour", systemImage: "sparkles.rectangle.stack") }.glassButton()
            }
            section("Updates", "arrow.down.app", Theme.blue, subtitle: "New versions") {
                HStack {
                    TextField("name/repository (optional)", text: $updateRepo).textFieldStyle(.roundedBorder)
                    Button { Task { await UpdateChecker.check(manual: true) } } label: { Label("Check now", systemImage: "arrow.clockwise") }.glassButton(prominent: true)
                }
                Text("Checks GitHub for new releases.").font(.caption).foregroundStyle(.secondary)
            }
            section("Backup & help", "lifepreserver", Theme.orange, subtitle: "Backup and support") {
                HStack {
                    Button { SettingsBackup.export() } label: { Label("Export settings…", systemImage: "square.and.arrow.up") }.glassButton()
                    Button { SettingsBackup.importFile() } label: { Label("Import settings…", systemImage: "square.and.arrow.down") }.glassButton()
                }
                Divider()
                Text("Copies versions, settings and recent logs. Cookies and private links are removed.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { ErrorReport.copy(manager: DownloadManager.shared) } label: { Label("Copy error report", systemImage: "doc.on.clipboard") }
                        .glassButton(tint: Theme.pink)
                        .help("Copies versions, settings and recent logs, without cookies")
                    Button { AppLog.confirmAndClear() } label: { Label("Clear log…", systemImage: "trash") }
                        .glassButton()
                        .help("Deletes the saved log and starts a new one")
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            tabBar
            Group {
                switch tab {
                case .status: statusPage
                case .downloads: downloadsPage
                case .files: filesPage
                case .sites: sitesPage
                case .app: appPage
                }
            }
        }
    }

    private func statusRow<T: View>(_ ok: Bool, _ title: String, _ note: String?, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(ok ? Theme.blue : Theme.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }

    private func row(ok: Bool, text: String) -> some View {
        statusRow(ok, text, nil) {
            Text(ok ? "Ready" : "Needs attention").font(.caption.weight(.semibold))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill((ok ? Theme.blue : Theme.orange).opacity(0.2)))
        }
    }

    private func toolRow(_ name: String, path: String?, note: String, canUpdate: Bool) -> some View {
        statusRow(path != nil, name, note) {
            if tools.busy.contains(name) {
                ProgressView().controlSize(.small)
            } else if path == nil {
                Button("Install") { Task { await tools.install(name) } }.glassButton(prominent: true)
            } else if canUpdate && tools.isManaged(path) {
                if tools.updateAvailable, let latest = tools.ytdlpLatest {
                    Button("Update to \(latest)") { Task { await tools.updateYtDlp() } }.glassButton(prominent: true)
                } else if let v = tools.ytdlpVersion {
                    Text("v\(v) · up to date").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Ready").font(.caption.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.blue.opacity(0.2)))
            }
        }
    }
}
