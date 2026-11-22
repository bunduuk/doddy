import Foundation
import AppKit

/// Optional: when you copy a media or video-site link, Doddy offers to download it.
extension DownloadManager {
    private static let mediaExt = ["mp4", "m4v", "webm", "mkv", "mov", "mp3", "m4a", "m3u8", "ts"]
    private static let sites = ["youtube.com", "youtu.be", "vimeo.com", "tiktok.com", "instagram.com", "twitter.com",
                                "x.com", "facebook.com", "fb.watch", "reddit.com", "twitch.tv", "dailymotion.com"]

    /// Turns copied/dropped text into a job, or nil when it is not a web link.
    func jobForLink(_ raw: String, anySite: Bool) -> Job? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count < 2000, !s.contains(" "), !s.contains("\n"),
              let u = URL(string: s), let scheme = u.scheme, scheme == "http" || scheme == "https",
              u.host != nil, let host = u.host?.lowercased() else { return nil }
        let ext = u.pathExtension.lowercased()
        let isMedia = Self.mediaExt.contains(ext)
        let isSite = Self.sites.contains { host == $0 || host.hasSuffix("." + $0) } && u.path.count > 1
        guard isMedia || isSite || anySite else { return nil }
        let kind = !isMedia ? "page" : (ext == "m3u8" ? "stream" : "file")
        var job = Job(url: s, kind: kind, pageUrl: s, title: nil)
        if isMedia { job.title = u.deletingPathExtension().lastPathComponent }
        return job
    }

    func pollClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastClipboardCount else { return }
        lastClipboardCount = pb.changeCount
        guard UserDefaults.standard.bool(forKey: "watchClipboard") else { return }
        guard let raw = pb.string(forType: .string), let job = jobForLink(raw, anySite: false) else { return }
        if items.contains(where: { $0.job.url == job.url || $0.job.pageUrl == job.url }) { return }
        Notifier.post("Link copied", URL(string: job.url)?.host ?? "")
        add(job)
    }

    /// Add link button, drag-and-drop and paste.
    func addLink(_ raw: String) {
        // "link | mirror | mirror": the same file at several addresses. The others are tried if the first fails.
        let parts = raw.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if var job = jobForLink(parts.first ?? raw, anySite: true) {
            let extra = parts.dropFirst().filter { $0.lowercased().hasPrefix("http") }
            if !extra.isEmpty && job.kind == "file" { job.mirrors = Array(extra) }
            add(job)
        } else {
            let a = NSAlert()
            a.messageText = "That isn't a web link"
            a.informativeText = "Copy a page or video address (starting with http) and try again."
            a.runModal()
        }
    }

    func askForLink() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Add a link"
        a.informativeText = "Paste a video, page or file address. For mirrors of one file, separate the links with | and Doddy tries the next if one fails."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://…"
        if let s = NSPasteboard.general.string(forType: .string), jobForLink(s, anySite: true) != nil {
            field.stringValue = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        a.accessoryView = field
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        if a.runModal() == .alertFirstButtonReturn { addLink(field.stringValue) }
    }
}
