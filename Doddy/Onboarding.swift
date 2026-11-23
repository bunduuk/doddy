import SwiftUI
import AppKit

/// First-launch checklist: tools, browser helper, Chrome extension, save folder.
struct OnboardingView: View {
    @ObservedObject var tools = ToolManager.shared
    @AppStorage("saveDir") private var saveDirStored = ""
    @State private var tick = 0
    var onDone: () -> Void
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var toolsReady: Bool { tools.ytdlpPath != nil && tools.ffmpegPath != nil }
    private var helperReady: Bool { _ = tick; return Installer.helperRegistered() }
    private var extensionSeen: Bool {
        _ = tick
        return FileManager.default.fileExists(atPath: Paths.support.appendingPathComponent("extension-seen").path)
    }
    private var folderPath: String { saveDirStored.isEmpty ? Paths.downloads.path : saveDirStored }

    private func card(_ ok: Bool, _ symbol: String, _ title: String, _ text: String) -> some View {
        card(ok, symbol, title, text) { EmptyView() }
    }

    private func card<A: View>(_ ok: Bool, _ symbol: String, _ title: String, _ text: String,
                               @ViewBuilder actions: () -> A) -> some View {
        let cols: [Color] = ok ? [Theme.cyan, Theme.blue] : [Theme.orange, Theme.yellow]
        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(LinearGradient(colors: cols, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 40, height: 40)
                Image(systemName: ok ? "checkmark" : symbol)
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 16, tint: ok ? Theme.blue : nil)
    }

    private var doneCount: Int { [toolsReady, helperReady, extensionSeen, true].filter { $0 }.count }
    private var allReady: Bool { extensionSeen && helperReady && toolsReady }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Doddy").font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [Theme.blue, Theme.violet, Theme.pink, Theme.orange],
                                                        startPoint: .leading, endPoint: .trailing))
                    Text(allReady ? "All set." : "Four quick steps.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(doneCount)/4").font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.blue.opacity(0.18)))
            }
            FunBar(value: Double(doneCount) / 4, colors: [Theme.blue, Theme.violet, Theme.pink, Theme.orange])
                .frame(height: 8)

            card(toolsReady, "arrow.down.circle", "1. Download tools",
                 toolsReady ? "yt-dlp and ffmpeg are installed."
                            : (tools.busy.isEmpty ? "yt-dlp and ffmpeg are missing. Doddy is installing them."
                                                  : "Installing \(tools.busy.joined(separator: ", "))…"))

            card(helperReady, "link", "2. Browser helper",
                 helperReady ? "Doddy is connected to your browser." : "Not connected. Open Chrome once, then restart Doddy.")

            card(extensionSeen, "puzzlepiece.extension", "3. Chrome extension",
                 extensionSeen ? "Connected. Chrome downloads and video Download buttons now go to Doddy."
                               : "Open chrome://extensions, turn on Developer mode, press Load unpacked and choose the extension folder.") {
                if !extensionSeen {
                    HStack {
                        Button("Show folder") { Installer.revealExtensionFolder() }.glassButton()
                        Button("Open Chrome extensions") { Installer.openChromeExtensionsPage() }.glassButton(prominent: true)
                    }
                }
            }

            card(true, "folder", "4. Where to save", folderPath) {
                Button("Change folder…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                    p.directoryURL = URL(fileURLWithPath: folderPath)
                    if p.runModal() == .OK, let u = p.url { saveDirStored = u.path }
                }
                .glassButton()
            }

            HStack {
                Text("Replay this anytime from Setup.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(allReady ? "Get started" : "Continue") { onDone() }
                    .glassButton(prominent: true)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 540)
        .background(ColorfulBackdrop(colors: [Theme.blue, Theme.orange]))
        .onReceive(timer) { _ in tick += 1; tools.refresh() }
    }
}
