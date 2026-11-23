import Foundation
import AppKit
import SwiftUI

// MARK: - Dock badge, Dock progress bar, sounds

/// The Dock icon: a count badge, and a progress bar along the bottom while downloads run.
@MainActor
enum DockStatus {
    private static var lastKey = ""

    static func update(items: [DownloadItem]) {
        let running = items.filter { $0.state == .running }
        let waiting = items.filter { $0.state == .queued }.count
        let badge = running.count + waiting
        // Overall progress: the average of the downloads that know theirs.
        let known = running.compactMap { $0.progress >= 0 ? $0.progress : nil }
        let avg = known.isEmpty ? -1 : known.reduce(0, +) / Double(known.count)
        let key = "\(badge)|\(Int(avg * 100))"
        guard key != lastKey else { return }
        lastKey = key

        let tile = NSApp.dockTile
        tile.badgeLabel = badge > 0 ? String(badge) : nil
        if running.isEmpty {
            tile.contentView = nil
        } else {
            let v = DockBarView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
            v.value = avg
            tile.contentView = v
        }
        tile.display()
    }
}

private final class DockBarView: NSView {
    var value: Double = -1

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let bar = NSRect(x: 14, y: 8, width: bounds.width - 28, height: 12)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill()
        let frac = value < 0 ? 0.15 : max(0.06, min(1, value))
        let fill = NSRect(x: bar.minX + 2, y: bar.minY + 2, width: (bar.width - 4) * frac, height: bar.height - 4)
        NSColor(calibratedRed: 0.20, green: 0.84, blue: 0.52, alpha: 1).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 4, yRadius: 4).fill()
    }
}

enum Sounds {
    static func finished() {
        guard UserDefaults.standard.object(forKey: "finishSound") as? Bool ?? true else { return }
        NSSound(named: "Glass")?.play()
    }
    static func failed() {
        guard UserDefaults.standard.object(forKey: "finishSound") as? Bool ?? true else { return }
        NSSound(named: "Basso")?.play()
    }
}

// MARK: - Error report

/// A short text to paste into a message: versions, settings and the tail of the log, with cookies
/// and the secret parts of links (everything after "?") removed.
extension AppLog {
    /// Asks first, then empties the log. A new log starts straight away.
    static func confirmAndClear() {
        let a = NSAlert()
        a.messageText = "Clear the log?"
        a.informativeText = "This deletes the saved log (\(sizeText)). A new, empty log starts right away."
        a.addButton(withTitle: "Clear log")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { clear() }
    }
}

@MainActor
enum ErrorReport {
    private static func scrub(_ s: String) -> String {
        var t = s
        let rules: [(String, String)] = [
            ("(?i)(cookie[\"']?\\s*[:=]\\s*)[^\\n]*", "$1<hidden>"),
            ("(?i)(authorization[\"']?\\s*[:=]\\s*)[^\\n]*", "$1<hidden>"),
            ("(https?://[^\\s\"'?#|]+)\\?[^\\s\"'|]*", "$1?<hidden>"),
            ("/Users/[^/\\s]+/", "/Users/<you>/"),
        ]
        for (p, r) in rules {
            if let re = try? NSRegularExpression(pattern: p) {
                t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: r)
            }
        }
        return t
    }

    private static func tail(of url: URL, maxBytes: Int = 200_000, lines: Int = 250) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "(no log file yet)" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        let data = (try? h.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    static func build(manager: DownloadManager) -> String {
        let d = UserDefaults.standard
        let info = Bundle.main.infoDictionary
        var out = "Doddy report\n"
        out += "Version: \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))\n"
        out += "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "yt-dlp: \(Tools.find("yt-dlp") ?? "missing"), ffmpeg: \(Tools.find("ffmpeg") ?? "missing")\n"
        let keys = ["askBeforeDownload", "maxParallel", "speedLimitKB", "subtitlesOn", "translateSubs", "convertAfter",
                    "cleanNames", "chromeCookies", "sortFolders", "watchClipboard", "nameTemplate"]
        out += "Settings: " + keys.map { "\($0)=\(d.object(forKey: $0).map { "\($0)" } ?? "default")" }.joined(separator: ", ") + "\n\n"
        out += "Downloads (latest 12):\n"
        for i in manager.items.prefix(12) {   // newest first
            var h = i.sourceHost
            if h.hasPrefix("www.") { h.removeFirst(4) }
            out += "- \(i.state.key) | \(h) | \(i.job.kind) | \(i.method)"
            if !i.detail.isEmpty { out += " | " + i.detail.replacingOccurrences(of: "\n", with: " ").prefix(300) }
            out += "\n"
        }
        out += "\nLog (latest lines):\n" + tail(of: AppLog.url)
        return scrub(out)
    }

    static func copy(manager: DownloadManager) {
        let text = build(manager: manager)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let a = NSAlert()
        a.messageText = "Report copied"
        a.informativeText = "Paste it into your message. Cookies and private links are removed. Give it a quick read before sending."
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

// MARK: - Dock presence

/// Closing the window removes Doddy from the Dock but keeps it running in the menu bar to catch downloads.
@MainActor
enum DockMode {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let closing = note.object as? NSWindow, closing.styleMask.contains(.titled) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let stillOpen = NSApp.windows.contains {
                        $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) && !$0.isMiniaturized
                    }
                    if !stillOpen { NSApp.setActivationPolicy(.accessory) }
                }
            }
        }
    }

    static func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
