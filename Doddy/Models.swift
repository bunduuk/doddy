import Foundation
import SwiftUI

enum Paths {
    static let support: URL = {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = root.appendingPathComponent("Doddy", isDirectory: true)
        // Earlier builds were called NeatMac: bring their history and tools across once.
        let old = root.appendingPathComponent("NeatMac", isDirectory: true)
        if !fm.fileExists(atPath: u.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: u)
            try? fm.removeItem(at: u.appendingPathComponent("host.sh"))   // rewritten for the new name at launch
        }
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var queue: URL { support.appendingPathComponent("queue", isDirectory: true) }
    static var extensionDir: URL { support.appendingPathComponent("extension", isDirectory: true) }
    static var bin: URL { support.appendingPathComponent("bin", isDirectory: true) }
    static var hostScript: URL { support.appendingPathComponent("host.sh") }
    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Doddy", isDirectory: true)
    }
}

/// A stream/file the extension spotted on the page; used as a fallback.
struct Candidate: Codable {
    var url: String
    var kind: String
    var referer: String?
    var userAgent: String?
    var acceptLanguage: String?    // exactly what the browser sent; some sites tie links to it
    var browserHeaders: [String: String]?   // the browser's identity headers (no cookies), copied as sent
    var cookies: String?
    var size: Int64?
    var type: String?
    var playlistText: String?   // playlist as Chrome read it (the link may work only once)
    var variantUrl: String?
    var variantText: String?
    var keyData: [String: String]?   // AES keys as Chrome read them (URL -> base64)
}

/// A download request as sent by the browser extension.
struct Job: Codable {
    var action: String?
    var url: String
    var kind: String          // "file" | "stream" | "page"
    var pageUrl: String?
    var title: String?
    var referer: String?
    var userAgent: String?
    var acceptLanguage: String?
    var browserHeaders: [String: String]?
    var cookies: String?
    var candidates: [Candidate]?
    var sourceUrl: String?      // download this URL instead of the page (a stream chosen from the quality list)
    var formatHeight: Int?      // cap video height, e.g. 1080
    var audioOnly: Bool?
    var playlist: Bool?         // download every video of a playlist
    var sizeHint: Int64?        // size seen by the browser, for the details window
    var qualityLabel: String?   // e.g. "1080p", for the details window
    var saveDir: String?        // chosen in the details window
    var playlistText: String?   // playlist as Chrome read it (the link may work only once)
    var variantUrl: String?     // the quality's playlist, read by Chrome too
    var variantText: String?
    var keyData: [String: String]?   // AES keys as Chrome read them (URL -> base64)
    var convertAfter: String?        // from a site rule: none / mp4 / mp3 / m4a
    var cleanNames: Bool?            // from a site rule
    var chromeCookies: Bool?         // from a site rule
    var refreshId: String?           // a new link for the download with this id (Refresh link)
    var resumeKey: String?           // keeps the folder of unfinished parts stable when the link changes
    var customName: Bool?            // the user typed their own file name
    var mirrors: [String]?           // other addresses of the same file, tried when the first fails
    var quiet: Bool?                 // started from the link grabber: no details window, no duplicate prompt
    var addressForgotten: Bool?      // finished download whose address and referrer were not kept (Setup → Files)

    var headerFields: [String: String] {
        var h: [String: String] = [:]
        h["User-Agent"] = (userAgent?.isEmpty == false) ? userAgent! :
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Doddy/0.2"
        if let r = referer, !r.isEmpty {
            h["Referer"] = r
            // Many video CDNs also check Origin (hotlink protection), as the browser would send it.
            if let u = URL(string: r), let scheme = u.scheme, let host = u.host {
                h["Origin"] = "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? "")
            }
        }
        if let c = cookies, !c.isEmpty { h["Cookie"] = c }
        // The rest of what a browser sends on a media request; some CDNs refuse requests without it.
        h["Accept"] = "*/*"
        h["Accept-Language"] = (acceptLanguage?.isEmpty == false) ? acceptLanguage! : "en-GB,en;q=0.9"
        h["Sec-Fetch-Mode"] = "cors"
        h["Sec-Fetch-Dest"] = "empty"
        let sameSite = URL(string: url)?.host == URL(string: referer ?? "")?.host
        h["Sec-Fetch-Site"] = sameSite ? "same-origin" : "cross-site"
        // Copy-first: whatever the browser really sent for this video wins over the guesses above.
        // (Sec-Fetch-* stays computed, because the video parts may sit on another host than the playlist.)
        for (k, v) in browserHeaders ?? [:] where !v.isEmpty {
            let name = k.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
            if name.hasPrefix("Sec-Fetch") || name == "Cookie" || name == "Authorization" { continue }
            h[name] = v
        }
        return h
    }
}

enum DLState: Equatable {
    case pending, queued, running, paused, done, failed, cancelled

    var label: String {
        switch self {
        case .pending: return "Needs your OK"
        case .queued: return "Queued"
        case .running: return "Downloading"
        case .paused: return "Paused"
        case .done: return "Finished"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    var job: Job
    var started = Date()                       // when this run began (reset by start/resume)
    var baseProgress: Double = -1              // progress when this run began, for the time-left estimate

    @Published var title: String
    @Published var state: DLState = .queued {
        // Lists, counts and the menu bar read every download's state through the manager:
        // tell them when one changes (adding or removing a download already does).
        didSet { if oldValue != state { DownloadManager.shared.objectWillChange.send() } }
    }
    @Published var hiddenInMenu = false       // cleared from the menu bar list only; it stays in the app
    @Published var progress: Double = -1      // -1 = unknown
    @Published var speed: String = ""
    @Published var detail: String = ""
    @Published var method: String = ""      // "yt-dlp", "Stream", "Direct file"
    @Published var saveDir: URL = {
        if let p = UserDefaults.standard.string(forKey: "saveDir") { return URL(fileURLWithPath: p, isDirectory: true) }
        return Paths.downloads
    }()
    @Published var outputURL: URL?
    var task: Task<Void, Never>?
    let resume = ResumeBox()          // segment progress, for pause/resume of direct files
    var wantsPause = false
    var fromRule = false              // the folder came from a site rule
    var waiting = false               // queued because the "downloads at once" limit was reached
    @Published var canPause = false
    @Published var history: [Double] = []   // download speed, bytes per second, about one sample a second
    var lastSample = Date.distantPast
    var retries = 0                   // automatic retries used so far
    var addedAt = Date()              // when the download was first added
    var finishedAt: Date?             // when it completed
    var expectedBytes: Int64 = 0      // size the server announced (0 = unknown)
    var savedBytes: Int64 = 0         // size of the file when it completed

    init(job: Job) {
        self.job = job
        let t = (job.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = t.isEmpty ? (URL(string: job.url)?.host ?? "Video") : t
    }

    /// The job with whatever the user changed in the details window.
    var effectiveJob: Job {
        var j = job
        j.title = title
        j.saveDir = saveDir.path
        return j
    }

    var sourceHost: String {
        URL(string: job.pageUrl ?? job.url)?.host ?? "Unknown site"
    }

    var kindDescription: String {
        if job.playlist == true { return "Whole playlist" }
        if job.audioOnly == true { return "Audio only (MP3)" }
        if let h = job.formatHeight { return "Video up to \(h)p" }
        if let q = job.qualityLabel, !q.isEmpty { return "Video, \(q)" }
        switch job.kind {
        case "file":
            let media: Set<String> = ["mp4", "mkv", "webm", "mov", "m4v", "avi", "flv", "ts", "mp3", "m4a", "aac", "wav", "flac", "ogg"]
            let e = URL(string: job.url)?.pathExtension.lowercased() ?? ""
            return media.contains(e) ? "Video file" : "File"
        case "stream": return "Video stream, best quality"
        default: return "Page, best available quality"
        }
    }

    var sizeText: String? {
        guard let n = job.sizeHint, n > 0 else { return nil }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    func reset() {
        started = Date()
        baseProgress = -1
        state = .running
        history = []
        progress = -1
        speed = ""
        detail = ""
        outputURL = nil
    }
}

enum DLError: LocalizedError {
    case msg(String)
    case changed(String)      // the file on the server is not the one the saved pieces came from
    case noSpace(String)
    var errorDescription: String? {
        switch self {
        case .msg(let s), .noSpace(let s): return s
        case .changed(let why):
            return "The file changed on the server (\(why)) since this download started, so the partial file was discarded. Press retry to download the new version."
        }
    }
}

/// Remembers which servers asked us to slow down (HTTP 429), so we stop pushing them.
final class RateGate {
    static let shared = RateGate()
    private let lock = NSLock()
    private var slowUntil: [String: Date] = [:]
    private var lastLog: [String: Date] = [:]
    private var lastSeconds = 0
    private var learnedWidth: [String: Int] = [:]
    private var learnedGap: [String: TimeInterval] = [:]

    /// A server answered 429. Returns true when this is worth writing to the log (once per 20 seconds per server).
    @discardableResult
    func hit(_ host: String, retryAfter: Int?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        lastSeconds = min(max(retryAfter ?? 0, 0), 900)
        slowUntil[host] = Date().addingTimeInterval(600)
        let first = Date().timeIntervalSince(lastLog[host] ?? .distantPast) > 20
        if first { lastLog[host] = Date() }
        return first
    }

    /// What was learned about a server that asked us to slow down; the next try starts there (for ten minutes).
    func learn(_ host: String, width: Int, gap: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        learnedWidth[host] = width
        learnedGap[host] = gap
        slowUntil[host] = Date().addingTimeInterval(600)
    }

    /// How many parts to start with: 4 for a new server (it speeds up while the answers are good),
    /// or what was learned lately about this one.
    func width(for host: String?) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let h = host, let t = slowUntil[h], t > Date() else { return 4 }
        return learnedWidth[h] ?? 2
    }

    /// The gap between requests to start with (none for a server that has not complained lately).
    func gap(for host: String?) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let h = host, let t = slowUntil[h], t > Date() else { return 0 }
        return learnedGap[h] ?? 0.5
    }

    /// Seconds the server asked us to wait (0 when it did not say).
    var retryAfter: Int { lock.lock(); defer { lock.unlock() }; return lastSeconds }

    static func isRateLimit(_ text: String) -> Bool {
        text.contains("HTTP 429") || text.contains("Error 429") || text.contains("Too Many Requests")
    }
}

func safeName(_ s: String?, fallback: String = "video") -> String {
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
    let cleaned = (s ?? "").components(separatedBy: bad).joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let name = String(cleaned.prefix(120))
    return name.isEmpty ? fallback : name
}

func uniqueURL(_ url: URL) -> URL {
    let fm = FileManager.default
    var candidate = url
    var i = 1
    let base = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    while fm.fileExists(atPath: candidate.path) {
        let n = "\(base) (\(i))" + (ext.isEmpty ? "" : ".\(ext)")
        candidate = url.deletingLastPathComponent().appendingPathComponent(n)
        i += 1
    }
    return candidate
}

enum AppLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The old NeatMac log is not carried over (it may hold details from before the clean-up rules).
        for old in ["neatmac.log", "neatmac.log.old"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
        return dir.appendingPathComponent("doddy.log")
    }()

    /// Strips everything that could identify the person or what they watch, before a line reaches the file:
    /// links shrink to site + file type, cookies and tokens go, home-folder names, e-mail addresses and
    /// IP addresses go. Only what is needed to work out a problem stays.
    static func clean(_ input: String) -> String {
        var t = input
        func regex(_ pattern: String, _ template: String) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: template)
        }
        regex("(?i)(cookie[\"']?\\s*[:=]\\s*)[^\\n]*", "$1<hidden>")
        regex("(?i)(authorization[\"']?\\s*[:=]\\s*)[^\\n]*", "$1<hidden>")
        if let re = try? NSRegularExpression(pattern: "https?://[^\\s\"'|)>\\]]+") {
            let ns = t as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += shortLink(ns.substring(with: m.range))
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            t = out
        }
        regex("/Users/[^/\\s]+/", "~/")
        regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "<email>")
        regex("\\b\\d{1,3}(\\.\\d{1,3}){3}\\b", "<ip>")
        regex("[A-Za-z0-9_-]{32,}", "<id>")
        return t
    }

    /// "https://site.com/some/long/path/name.m3u8?token=…" becomes "https://site.com/…/*.m3u8".
    private static func shortLink(_ s: String) -> String {
        guard let u = URL(string: s), let host = u.host else { return "<link>" }
        let ext = u.pathExtension.lowercased()
        let kind = (!ext.isEmpty && ext.count <= 5) ? "/…/*.\(ext)" : "/…"
        return "\(u.scheme ?? "https")://\(host)\(kind)"
    }

    private static let lock = NSLock()
    private static var writes = 0

    static func write(_ raw: String) {
        let line = clean(raw)
        let data = (line + "\n").data(using: .utf8) ?? Data()
        lock.lock(); defer { lock.unlock() }      // several downloads log at once
        writes += 1
        if writes % 100 == 1 { keepSmall() }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            do { _ = try h.seekToEnd(); try h.write(contentsOf: data) } catch { }   // a full disk must not crash the app
        } else {
            try? data.write(to: url)
        }
    }

    /// The log never grows past a few MB: a big one is set aside as doddy.log.old (one generation only).
    private static func keepSmall() {
        let n = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard n > 3_000_000 else { return }
        let old = url.appendingPathExtension("old")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    /// Size of the log file, for display.
    static var sizeText: String {
        let n = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Empties the log; the next line starts a fresh one.
    static func clear() {
        try? FileManager.default.removeItem(at: url.appendingPathExtension("old"))
        try? Data().write(to: url)
        write("Log cleared \(Date())")
    }
}
