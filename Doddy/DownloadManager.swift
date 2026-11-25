import Foundation
import AppKit

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published var items: [DownloadItem] = []
    private var timer: Timer?
    var saveTick = 0
    var lastSaveSig = 0   // what the list looked like at the last save: nothing changed, nothing to encode
    @Published var holdUntil: Date?     // scheduler: new downloads wait until then
    var holdMinutes = -1
    var wasBusy = false
    var lastSavedHistory = Data()
    var saving = false
    var lastClipboardCount = NSPasteboard.general.changeCount

    init() {
        try? FileManager.default.createDirectory(at: Paths.queue, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Paths.downloads, withIntermediateDirectories: true)
        // Nothing is downloading yet: pieces Chrome fetched for an earlier run (Doddy quit or crashed
        // mid-download) are not needed. A download that resumes asks Chrome again.
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            for sub in ["parts", "wanted"] {
                let dir = Paths.support.appendingPathComponent(sub, isDirectory: true)
                for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollQueue()
                self?.pollRPC()
                self?.saveHistory()
                self?.tickSchedule()
                self?.pollClipboard()
                if let s = self { DockStatus.update(items: s.items) }
            }
        }
        Task { @MainActor [weak self] in self?.loadHistory() }   // after the app has finished launching
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if let self { Maintenance.autoClean(manager: self) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveHistory(force: true) }
        }
    }

    var activeCount: Int { items.filter { $0.state == .running }.count }

    /// Jobs arrive as JSON files dropped into the queue folder by the native host.
    func pollQueue() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Paths.queue, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f),
               let job = try? JSONDecoder().decode(Job.self, from: data) {
                add(job)
            }
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// Quality-list requests from the browser helper. Runs yt-dlp here, not under Chrome.
    func pollRPC() {
        let dir = Paths.support.appendingPathComponent("rpc", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasSuffix(".req.json") {
            let resURL = dir.appendingPathComponent(
                f.lastPathComponent.replacingOccurrences(of: ".req.json", with: ".res.json"))
            guard let data = try? Data(contentsOf: f) else { continue }
            try? FileManager.default.removeItem(at: f) // claim it so it runs once
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            Task.detached(priority: .userInitiated) {
                let result = HostMode.listFormats(obj)
                if let out = try? JSONSerialization.data(withJSONObject: result) {
                    try? out.write(to: resURL, options: .atomic)
                }
            }
        }
    }

    private func sourceKey(_ j: Job) -> String {
        let u = (j.sourceUrl ?? j.pageUrl ?? j.url).components(separatedBy: "?").first ?? ""
        return "\(u)|\(j.formatHeight ?? 0)|\(j.audioOnly == true)"
    }

    /// Warns when the same video is already in the list.
    private func confirmDuplicate(_ job: Job) -> Bool {
        let key = sourceKey(job)
        guard let dup = items.first(where: { sourceKey($0.job) == key && $0.state != .failed && $0.state != .cancelled }) else { return true }
        if job.quiet == true { return false }   // the link grabber skips what is already there
        let a = NSAlert()
        a.messageText = dup.state == .done ? "You already downloaded this" : "This is already in your list"
        a.informativeText = "\u{201C}\(dup.title)\u{201D} \u{2014} download it again?"
        a.addButton(withTitle: "Skip")
        a.addButton(withTitle: "Download again")
        return a.runModal() == .alertSecondButtonReturn
    }

    func add(_ incoming: Job, again: Bool = false) {
        var job = incoming
        if let rid = job.refreshId, let existing = items.first(where: { $0.id.uuidString == rid }) {
            applyRefresh(existing, job)
            return
        }
        if job.resumeKey == nil { job.resumeKey = stableHash(job.url) }
        let rule = SiteRules.apply(to: &job)
        guard again || confirmDuplicate(job) else { return }
        let item = DownloadItem(job: job)
        if let r = rule, !r.folder.isEmpty {
            item.saveDir = URL(fileURLWithPath: r.folder, isDirectory: true)
            item.fromRule = true
        }
        items.insert(item, at: 0)
        let ask = (job.quiet != true) && (UserDefaults.standard.object(forKey: "askBeforeDownload") as? Bool ?? true)
        if ask {
            item.state = .pending
            ConfirmPanelController.show(item, manager: self)
        } else {
            start(item)
        }
    }

    /// Starts a finished, failed or stopped download over as a new one, from the same address and referrer.
    func downloadAgain(_ item: DownloadItem) {
        guard item.job.addressForgotten != true else { return }
        var j = item.effectiveJob
        j.refreshId = nil
        j.resumeKey = nil
        j.quiet = nil
        add(j, again: true)
    }

    // MARK: Refresh link (IDM-style)

    /// Asks Chrome to capture a new link for this download from its page. The pieces already downloaded are kept.
    func requestRefresh(_ item: DownloadItem) {
        guard let page = item.job.pageUrl ?? item.job.referer, let url = URL(string: page) else {
            item.detail = "No page to refresh from."
            return
        }
        let dir = Paths.support.appendingPathComponent("refresh", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let req: [String: Any] = ["id": item.id.uuidString, "pageUrl": page, "kind": item.job.kind,
                                  "size": item.resume.total, "time": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: req) {
            try? data.write(to: dir.appendingPathComponent(item.id.uuidString + ".json"), options: .atomic)
        }
        item.detail = "Waiting for Chrome. Play the video on the page that opened, and Doddy continues where it stopped."
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// The extension sent a fresh link for an existing download.
    private func applyRefresh(_ item: DownloadItem, _ new: Job) {
        let file = Paths.support.appendingPathComponent("refresh", isDirectory: true)
            .appendingPathComponent(item.id.uuidString + ".json")
        try? FileManager.default.removeItem(at: file)
        // A file of a different size is a different file: do not mix the two.
        if item.job.kind == "file", item.resume.total > 0, let n = new.sizeHint, n > 0,
           abs(Double(n - item.resume.total)) > Double(item.resume.total) * 0.01 {
            item.detail = "The new link is a different file. Nothing changed."
            NSSound.beep()
            return
        }
        var j = item.job
        j.url = new.url
        j.referer = new.referer
        j.userAgent = new.userAgent
        j.acceptLanguage = new.acceptLanguage
        j.browserHeaders = new.browserHeaders
        j.cookies = new.cookies
        j.playlistText = new.playlistText
        j.variantUrl = new.variantUrl
        j.variantText = new.variantText
        j.keyData = new.keyData
        j.sizeHint = new.sizeHint ?? j.sizeHint
        item.job = j
        item.detail = ""
        AppLog.write("refreshed link: \(new.url)")
        Notifier.post("Link refreshed", item.title)
        start(item, force: true)
    }

    /// Called by the details window.
    func confirm(_ item: DownloadItem, startNow: Bool) {
        if !item.fromRule { UserDefaults.standard.set(item.saveDir.path, forKey: "saveDir") }
        if startNow { start(item) } else { item.state = .queued }
    }

    var maxParallel: Int {
        let n = UserDefaults.standard.integer(forKey: "maxParallel")
        return n > 0 ? n : 3
    }

    /// Starts the oldest waiting downloads while there is a free slot.
    func pump() {
        while !isHeld, activeCount < maxParallel, let next = items.last(where: { $0.waiting }) {
            next.waiting = false
            start(next, force: true)
        }
    }

    func start(_ item: DownloadItem, force: Bool = false) {
        if !force && (activeCount >= maxParallel || isHeld) {
            item.state = .queued
            item.waiting = true
            return
        }
        item.waiting = false
        item.wantsPause = false
        item.reset()
        if UserDefaults.standard.object(forKey: "showProgressWindow") as? Bool ?? true {
            ProgressPanelController.show(item, manager: self)
        }
        item.task = Task { [weak self] in
            await self?.run(item)
        }
    }

    func cancel(_ item: DownloadItem) {
        item.wantsPause = false
        item.waiting = false
        item.task?.cancel()
        item.resume.discard()
        item.state = .cancelled
        pump()
    }

    /// Keeps what was downloaded so far; Resume continues from there.
    func pause(_ item: DownloadItem) {
        guard item.state == .running else { return }
        item.wantsPause = true
        item.task?.cancel()
    }

    func resume(_ item: DownloadItem) {
        start(item, force: true)
    }

    func remove(_ item: DownloadItem) {
        item.wantsPause = false
        item.task?.cancel()
        item.resume.discard()
        items.removeAll { $0.id == item.id }
        pump()
    }

    /// Moves the downloaded file to the Trash (recoverable) and removes the entry.
    func removeWithFile(_ item: DownloadItem) {
        trashFile(of: item)
        remove(item)
    }

    private func trashFile(of item: DownloadItem) {
        guard item.state == .done, let u = item.outputURL,
              FileManager.default.fileExists(atPath: u.path) else { return }
        try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
    }

    /// Empties the list. Running downloads are cancelled. Optionally trashes finished files too.
    func clearAll(deleteFiles: Bool) {
        for item in items {
            item.task?.cancel()
            item.resume.discard()
            item.waiting = false
            if deleteFiles { trashFile(of: item) }
        }
        items.removeAll()
    }

    func clearFinished() {
        for i in items where i.state == .cancelled || i.state == .failed { i.resume.discard() }   // their unfinished pieces
        items.removeAll { $0.state == .done || $0.state == .cancelled || $0.state == .failed }
    }

    func reveal(_ item: DownloadItem) {
        guard let u = item.outputURL else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([u])
        } else {
            NSWorkspace.shared.open(Paths.downloads)
        }
    }

    /// Waits a little (5, 10, 20… seconds) and starts the download again after a temporary problem.
    private func scheduleRetry(_ item: DownloadItem, _ error: Error) -> Bool {
        let limit = UserDefaults.standard.object(forKey: "autoRetry") as? Int ?? 2
        let text = error.localizedDescription
        let permanent = ["Unsupported URL", "not installed", "HTTP 401", "HTTP 403", "HTTP 404", "HTTP 410", "Bad URL", "copy-protected"]
        guard limit > 0, item.retries < limit, !permanent.contains(where: { text.contains($0) }) else { return false }
        item.retries += 1
        let rate = RateGate.isRateLimit(text)
        // A site that says "slow down" gets a real pause (a minute or more), not the quick 5-second retry.
        let wait = rate ? min(max(RateGate.shared.retryAfter, [60, 180, 300][min(item.retries - 1, 2)]), 900)
                        : 5 * (1 << (item.retries - 1))
        item.state = .queued
        item.speed = ""
        item.detail = rate ? "The site asks Doddy to slow down (HTTP 429). Waiting \(wait)s before trying again (\(item.retries) of \(limit))."
                           : "\(text.prefix(120)). Retrying in \(wait)s (\(item.retries) of \(limit))."
        AppLog.write("auto-retry \(item.retries)/\(limit) in \(wait)s after: \(text)")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            guard let self, item.state == .queued else { return }
            self.start(item, force: true)
        }
        return true
    }

    private func perform(_ job: Job, _ item: DownloadItem) async throws -> URL {
        let progress: ProgressFn = { p, sp in
            Task { @MainActor in
                if item.baseProgress < 0 && p >= 0 { item.baseProgress = p }
                item.progress = p
                item.speed = sp
                item.addSample(sp)
            }
        }
        switch job.kind {
        case "file":
            item.method = "Direct file"
            item.canPause = true
            return try await Downloaders.file(job, box: item.resume, progress: progress)
        case "stream":
            item.method = "HLS"
            item.canPause = true
            do {
                return try await Downloaders.hls(job, box: item.resume, progress: progress)
            } catch HLSFallback.needFFmpeg(let why) {
                AppLog.write("native HLS not used (\(why)); using ffmpeg")
                item.method = "Stream"
                item.canPause = false
                return try await Downloaders.stream(job, progress: progress)
            }
        default:
            item.method = "yt-dlp"
            item.canPause = true   // yt-dlp continues from the pieces in its hidden folder
            return try await Downloaders.page(job, box: item.resume, progress: progress)
        }
    }

    /// Streams first, then bigger files. Every detected candidate gets a turn.
    private static func fallbackJobs(for job: Job) -> [Job] {
        let cands = (job.candidates ?? []).sorted {
            if ($0.kind == "stream") != ($1.kind == "stream") { return $0.kind == "stream" }
            return ($0.size ?? 0) > ($1.size ?? 0)
        }
        return cands.map { c in
            var j = Job(url: c.url, kind: c.kind, pageUrl: job.pageUrl, title: job.title,
                        referer: c.referer, userAgent: c.userAgent, cookies: c.cookies)
            j.saveDir = job.saveDir
            j.acceptLanguage = c.acceptLanguage
            j.browserHeaders = c.browserHeaders
            j.playlistText = c.playlistText
            j.variantUrl = c.variantUrl
            j.variantText = c.variantText
            j.keyData = c.keyData
            return j
        }
    }

    /// Asks for the first byte of a link. Returns a file (or stream) job when the answer is not a web page.
    private static func fileBehindLink(_ job: Job) async -> Job? {
        guard let url = URL(string: job.url) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        job.headerFields.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (bytes, resp) = try? await URLSession.shared.bytes(for: req) else { return nil }
        bytes.task.cancel()
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.isEmpty || type.contains("html") || type.contains("xml") || type.contains("json") { return nil }
        var j = job
        j.kind = type.contains("mpegurl") ? "stream" : "file"
        if j.customName != true {
            let suggested = Downloaders.fileNameFromDisposition(http.value(forHTTPHeaderField: "Content-Disposition") ?? "")
            let fromURL = (http.url ?? url).lastPathComponent
            let name = suggested.isEmpty ? fromURL : suggested
            if !name.isEmpty && name != "/" { j.title = (name as NSString).deletingPathExtension }
        }
        AppLog.write("   the link is a file (\(type.split(separator: ";").first ?? "")), not a page: downloading it directly")
        return j
    }

    private static func knownYtDlpSite(_ job: Job) -> Bool {
        let h = (URL(string: job.pageUrl ?? job.url)?.host ?? "").lowercased()
        let known = ["youtube.com", "youtu.be", "vimeo.com", "tiktok.com", "instagram.com", "twitter.com",
                     "x.com", "facebook.com", "fb.watch", "reddit.com", "twitch.tv", "dailymotion.com"]
        return known.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    private func run(_ item: DownloadItem) async {
        defer { pump() }
        var job = item.effectiveJob
        do {
            // A link from an unknown site may be a plain file (a release download, an installer…). Ask the
            // server once: if it is not a web page, download it as a file — in pieces, with progress and its real name.
            if job.kind == "page", (job.candidates ?? []).isEmpty, job.formatHeight == nil, job.audioOnly != true,
               job.playlist != true, !Self.knownYtDlpSite(job), let f = await Self.fileBehindLink(job) {
                job = f
                if job.customName != true, let t = f.title, !t.isEmpty { item.title = t }
            }
            var out: URL
            // yt-dlp first only for sites it is known to handle. Elsewhere, on "Best available",
            // try what the browser actually saw (stream, then file) and keep yt-dlp as the last resort.
            let alts = Self.fallbackJobs(for: job)
            let auto = job.kind == "page" && job.formatHeight == nil && job.audioOnly != true
            var attempts: [Job] = [job]
            if job.kind == "page" && !alts.isEmpty {
                attempts = (auto && !Self.knownYtDlpSite(job)) ? alts + [job] : [job] + alts
            }
            var lastError: Error = DLError.msg("Nothing to download")
            var got: URL?
            var realError: Error?   // the most useful failure, not yt-dlp's "Unsupported URL" at the end
            if job.kind == "file", let mirrors = job.mirrors, !mirrors.isEmpty {
                attempts += mirrors.map { u in var j = job; j.url = u; j.mirrors = nil; return j }
            }
            for (i, a) in attempts.enumerated() {
                if i > 0 { AppLog.write("previous attempt failed (\(lastError.localizedDescription)); trying \(a.kind) \(a.url)") }
                AppLog.write("[\(Date())] attempt \(i + 1)/\(attempts.count): \(a.kind) \(a.url) | referer: \((a.referer ?? "").isEmpty ? "no" : "yes") | cookies: \((a.cookies ?? "").isEmpty ? "none" : "yes") | page link: \((a.pageUrl ?? "").isEmpty ? "no" : "yes")")
                item.progress = -1
                do {
                    got = try await perform(a, item)
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    lastError = error
                    AppLog.write("   failed: \(error.localizedDescription)")
                    if realError == nil && !error.localizedDescription.contains("Unsupported URL") { realError = error }
                    if error.localizedDescription.contains("copy-protected") { realError = error; break }
                    if RateGate.isRateLimit(error.localizedDescription) {
                        realError = error
                        AppLog.write("   the site is rate limiting; not trying other ways now")
                        break
                    }
                }
            }
            guard let g = got else { throw realError ?? lastError }
            out = g
            try Task.checkCancellation()
            if item.resume.expected > 0 { item.expectedBytes = item.resume.expected }
            if UserDefaults.standard.bool(forKey: "subtitlesOn") && job.audioOnly != true {
                item.progress = -1
                out = await Subtitles.process(out, translate: UserDefaults.standard.bool(forKey: "translateSubs")) { item.speed = $0 }
                try Task.checkCancellation()
            }
            let target = job.convertAfter ?? UserDefaults.standard.string(forKey: "convertAfter") ?? "none"
            if target != "none" {
                item.progress = -1
                item.speed = "Converting to \(target.uppercased())…"
                out = await Downloaders.convert(out, to: target,
                                                deleteOriginal: UserDefaults.standard.bool(forKey: "convertDeleteOriginal"))
                try Task.checkCancellation()
            }
            if job.cleanNames ?? UserDefaults.standard.bool(forKey: "cleanNames") {
                out = Naming.renameCleaned(out)
                item.title = out.deletingPathExtension().lastPathComponent
            }
            if job.customName != true && job.playlist != true {
                item.title = out.deletingPathExtension().lastPathComponent   // the real name, not the site it came from
            }
            item.outputURL = out
            item.finishedAt = Date()
            item.savedBytes = DownloadInfo.size(of: out)
            if item.expectedBytes == 0, let h = job.sizeHint, h > 0 { item.expectedBytes = h }
            if !AddressText.remember { item.job = item.job.forgettingAddresses() }
            item.retries = 0
            item.progress = 1
            item.speed = ""
            item.state = .done
            Notifier.post("Download finished", out.lastPathComponent, file: out)
            Sounds.finished()
        } catch is CancellationError {
            if item.wantsPause {
                item.wantsPause = false
                item.speed = ""
                item.state = .paused
            } else {
                item.resume.discard()
                item.state = .cancelled
            }
        } catch {
            if item.state == .cancelled { return }
            if item.wantsPause {
                // The pause surfaced as a transport error rather than a cancellation.
                item.wantsPause = false
                item.speed = ""
                item.state = .paused
                return
            }
            if scheduleRetry(item, error) { return }
            item.state = .failed
            var msg = error.localizedDescription
            if RateGate.isRateLimit(msg) {
                msg = "The site is rate limiting Doddy (HTTP 429), usually after too many requests in a short time. Wait 15 to 30 minutes without reloading the video, then press retry."
            }
            if (msg.contains("HTTP 404") || msg.contains("HTTP 410")) && job.kind != "page" {
                msg = "This link has probably expired. Use Refresh link, or play the video again in Chrome.\n\n" + msg
            }
            if msg.contains("Unsupported URL") && (job.candidates ?? []).isEmpty {
                msg = "No video found yet. Press play, then try Download again.\n\n" + msg
            }
            item.detail = msg
            Notifier.post("Download failed", msg)
            Sounds.failed()
        }
    }
}
