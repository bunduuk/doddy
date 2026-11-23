import Foundation

typealias ProgressFn = @Sendable (Double, String) -> Void

// MARK: - Multi-connection HTTP downloader

/// What is needed to continue a segmented download after a pause.
final class ResumeBox: @unchecked Sendable {
    var dest: URL?
    var total: Int64 = 0
    var ranged = false
    var segs: [[Int64]] = []      // [start, next, end] per segment
    var fractions: [Double] = []  // live progress of each segment, 0...1 (for the segment bar)
    func clear() { dest = nil; total = 0; ranged = false; segs = []; fractions = [] }
    func discard() {
        if let d = dest { try? FileManager.default.removeItem(at: d) }
        clear()
    }
}

final class RangedDownloader: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let headers: [String: String]
    private let dest: URL
    private let total: Int64
    private let ranged: Bool
    private let connections: Int
    private let progress: ProgressFn
    private let box: ResumeBox?

    private var session: URLSession!
    private var handle: FileHandle?
    private let lock = NSLock()
    private var offsets: [Int: Int64] = [:]
    private var segInfo: [Int: (Int64, Int64)] = [:]   // task id -> (start, end)
    private var received: Int64 = 0
    private var pending = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var lastTick = Date()
    private var lastBytes: Int64 = 0

    init(url: URL, headers: [String: String], dest: URL, total: Int64,
         ranged: Bool, connections: Int, progress: @escaping ProgressFn, box: ResumeBox? = nil) {
        self.url = url
        self.headers = headers
        self.dest = dest
        self.total = total
        self.ranged = ranged
        self.connections = connections
        self.progress = progress
        self.box = box
    }

    /// Remembers how far each segment got, so a later run can continue from there.
    private func saveSnapshot() {
        lock.lock()
        defer { lock.unlock() }
        guard let box, ranged else { return }
        var segs: [[Int64]] = []
        for (id, se) in segInfo {
            segs.append([se.0, min(offsets[id] ?? se.0, se.1 + 1), se.1])
        }
        segs.sort { $0[0] < $1[0] }
        box.segs = segs
    }

    func run() async throws {
        let resuming = (box?.segs.isEmpty == false) && FileManager.default.fileExists(atPath: dest.path)
        if !resuming { FileManager.default.createFile(atPath: dest.path, contents: nil) }
        handle = try FileHandle(forWritingTo: dest)
        if !resuming && ranged && total > 0 { try handle?.truncate(atOffset: UInt64(total)) }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = max(connections, 4)
        cfg.timeoutIntervalForRequest = 60
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)

        defer { try? handle?.close() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                continuation = cont
                var tasks: [URLSessionDataTask] = []
                var plan: [[Int64]] = []   // [start, next, end]
                if resuming, let box {
                    plan = box.segs
                    var remaining: Int64 = 0
                    for seg in plan where seg[1] <= seg[2] { remaining += seg[2] - seg[1] + 1 }
                    received = max(0, total - remaining)
                    lastBytes = received
                    plan = plan.filter { $0[1] <= $0[2] }
                } else if ranged && total > 0 {
                    let step = (total + Int64(connections) - 1) / Int64(connections)
                    for i in 0..<connections {
                        let s = Int64(i) * step
                        let e = min(total - 1, (Int64(i) + 1) * step - 1)
                        if s > e { break }
                        plan.append([s, s, e])
                    }
                }
                if resuming || (ranged && total > 0) {
                    for seg in plan {
                        var req = URLRequest(url: url)
                        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
                        req.setValue("bytes=\(seg[1])-\(seg[2])", forHTTPHeaderField: "Range")
                        let t = session.dataTask(with: req)
                        offsets[t.taskIdentifier] = seg[1]
                        segInfo[t.taskIdentifier] = (seg[0], seg[2])
                        tasks.append(t)
                    }
                } else {
                    var req = URLRequest(url: url)
                    headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
                    let t = session.dataTask(with: req)
                    offsets[t.taskIdentifier] = 0
                    tasks.append(t)
                }
                pending = tasks.count
                if tasks.isEmpty {
                    continuation = nil
                    lock.unlock()
                    cont.resume()
                    return
                }
                lock.unlock()
                tasks.forEach { $0.resume() }
            }
        } onCancel: {
            self.saveSnapshot()
            self.session?.invalidateAndCancel()
        }
    }

    private func finish(_ error: Error?) {
        if error != nil { saveSnapshot() }
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return }
        session.invalidateAndCancel()
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    // MARK: delegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            lock.lock(); let hasSegs = !segInfo.isEmpty; lock.unlock()
            let isRange = ranged || hasSegs
            let ok = isRange ? http.statusCode == 206 : (200..<300).contains(http.statusCode)
            if !ok {
                completionHandler(.cancel)
                finish(DLError.msg("Server answered HTTP \(http.statusCode)"))
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Speed limit: holding back the next read makes the connection slow down.
        let wait = SpeedLimiter.shared.delay(forBytes: data.count)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        let off = offsets[dataTask.taskIdentifier] ?? 0
        do {
            try handle.seek(toOffset: UInt64(off))
            try handle.write(contentsOf: data)
        } catch {
            DispatchQueue.global().async { self.finish(error) }
            return
        }
        offsets[dataTask.taskIdentifier] = off + Int64(data.count)
        received += Int64(data.count)

        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        if dt >= 0.4 {
            let bps = Double(received - lastBytes) / dt
            lastTick = now
            lastBytes = received
            if let box, ranged {
                box.segs = segInfo.sorted { $0.value.0 < $1.value.0 }.map { id, se in
                    [se.0, min(offsets[id] ?? se.0, se.1 + 1), se.1]
                }
                box.fractions = segInfo.sorted { $0.value.0 < $1.value.0 }.map { id, se in
                    let len = Double(se.1 - se.0 + 1)
                    return len > 0 ? min(1, max(0, Double((offsets[id] ?? se.0) - se.0) / len)) : 1
                }
            }
            let frac = total > 0 ? Double(received) / Double(total) : -1
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            progress(frac, fmt.string(fromByteCount: Int64(bps)) + "/s")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(error)
            return
        }
        lock.lock()
        pending -= 1
        let done = pending <= 0
        let short = done && ranged && total > 0 && received < total
        lock.unlock()
        // A connection that closed early without an error would leave a hole in the file: treat it as a failure
        // (the pieces are kept, so retry continues from where each one stopped).
        if short { finish(DLError.msg("The server closed the connection early. Press retry to continue.")) }
        else if done { finish(nil) }
    }
}

// MARK: - External tools (yt-dlp, ffmpeg)

enum Tools {
    static var searchPaths: [String] {
        let home = NSHomeDirectory()
        return [Paths.bin.path, "/opt/homebrew/bin", "/usr/local/bin",
                home + "/.homebrew/bin", "/usr/bin", "/bin"]
    }

    static func find(_ name: String) -> String? {
        for p in searchPaths {
            let c = p + "/" + name
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return nil
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        return env
    }

    /// Runs a tool, streaming each output line to `onLine`. Returns the exit status.
    static func run(_ exe: String, _ args: [String], onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        /// Collects output and hands it over one line at a time. One thread at a time touches it.
        final class Buffer: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func add(_ chunk: Data, _ emit: (String) -> Void) {
                lock.lock(); defer { lock.unlock() }
                data.append(chunk)
                // split on \n or \r (ffmpeg/yt-dlp progress uses both)
                while let idx = data.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                    let lineData = data.prefix(upTo: idx)
                    data.removeSubrange(data.startIndex...idx)
                    if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { emit(s) }
                }
            }
            /// The last line often has no line break after it, and it is often the error message.
            func flush(_ emit: (String) -> Void) {
                lock.lock(); defer { lock.unlock() }
                if let s = String(data: data, encoding: .utf8), !s.isEmpty { emit(s) }
                data.removeAll()
            }
        }
        let buf = Buffer()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { return }
            buf.add(chunk, onLine)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                p.terminationHandler = { proc in
                    // Give the last output a moment to arrive, then close up (never block waiting on the pipe).
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                        pipe.fileHandleForReading.readabilityHandler = nil
                        buf.flush(onLine)
                        cont.resume(returning: proc.terminationStatus)
                    }
                }
                // Cancelled before it even started: do not start it.
                if Task.isCancelled {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: CancellationError())
                    return
                }
                do { try p.run() } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }
}

// MARK: - Strategies

enum Downloaders {
    static func outDir(_ job: Job) -> URL {
        var u = job.saveDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Paths.downloads
        switch UserDefaults.standard.string(forKey: "sortFolders") ?? "none" {
        case "site":
            var h = URL(string: job.pageUrl ?? job.url)?.host ?? "Other"
            if h.hasPrefix("www.") { h.removeFirst(4) }
            u.appendPathComponent(h, isDirectory: true)
        case "type":
            u.appendPathComponent(job.audioOnly == true ? "Audio" : (job.kind == "file" ? "Files" : "Videos"), isDirectory: true)
        default: break
        }
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// The file name a server suggests in its Content-Disposition header, if any.
    static func fileNameFromDisposition(_ h: String) -> String {
        if let r = h.range(of: "filename*=") {
            var v = String(h[r.upperBound...]).components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces)
            if let q = v.range(of: "''") { v = String(v[q.upperBound...]) }
            return v.removingPercentEncoding ?? v
        }
        if let r = h.range(of: "filename=") {
            let v = String(h[r.upperBound...]).components(separatedBy: ";")[0]
            return v.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return ""
    }

    static func ext(url: URL, contentType: String, disposition: String = "") -> String {
        let d = (disposition as NSString).pathExtension.lowercased()
        if !d.isEmpty && d.count <= 5 { return "." + d }
        let e = url.pathExtension.lowercased()
        let dynamic: Set<String> = ["php", "asp", "aspx", "jsp", "cgi", "html", "htm", "do", "action"]
        if !e.isEmpty && e.count <= 5 && !dynamic.contains(e) { return "." + e }
        if contentType.contains("bittorrent") { return ".torrent" }
        if contentType.contains("zip") { return ".zip" }
        if contentType.contains("pdf") { return ".pdf" }
        if contentType.contains("mp2t") { return ".ts" }
        if contentType.contains("webm") { return ".webm" }
        if contentType.contains("mpeg") && contentType.hasPrefix("audio") { return ".mp3" }
        if contentType.hasPrefix("audio") { return ".m4a" }
        return ".mp4"
    }

    /// A file the server will only give to the browser: Chrome fetches it in pieces and hands them over.
    static func browserFile(_ job: Job, progress: @escaping ProgressFn) async throws -> URL {
        AppLog.write("   server refuses the app; asking Chrome to fetch the file")
        progress(-1, "Waiting for Chrome…")
        let fm = FileManager.default
        let id = stableHash(job.url)
        let wantedDir = Paths.support.appendingPathComponent("wanted", isDirectory: true)
        let partsDir = Paths.support.appendingPathComponent("parts", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try? fm.removeItem(at: partsDir)
        try fm.createDirectory(at: wantedDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: partsDir, withIntermediateDirectories: true)
        let reqFile = wantedDir.appendingPathComponent(id + ".json")
        let req: [String: Any] = ["id": id, "file": ["url": job.url]]
        try JSONSerialization.data(withJSONObject: req).write(to: reqFile, options: .atomic)
        defer {
            try? fm.removeItem(at: reqFile)
            try? fm.removeItem(at: reqFile.appendingPathExtension("claimed"))
            try? fm.removeItem(at: partsDir)
        }

        func failure() -> String? {
            for f in (try? fm.contentsOfDirectory(at: partsDir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "fail" {
                return (try? String(contentsOf: f, encoding: .utf8)) ?? "Chrome could not fetch the file"
            }
            return nil
        }

        // 1. Chrome says how big the file is and what it is called.
        var info: [String: Any]?
        var lastGot = Date()
        let metaFile = partsDir.appendingPathComponent("-1.raw")
        while info == nil {
            try Task.checkCancellation()
            if let why = failure() { throw DLError.msg(why) }
            if let d = try? Data(contentsOf: metaFile),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                info = o
                lastGot = Date()
            } else if Date().timeIntervalSince(lastGot) > 90 {
                throw DLError.msg("Chrome did not answer. Keep Chrome open with the Doddy extension on, then press retry.")
            } else {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        guard let meta = info,
              let total = (meta["total"] as? NSNumber)?.int64Value,
              let chunk = (meta["chunk"] as? NSNumber)?.int64Value, chunk > 0,
              let count = (meta["count"] as? NSNumber)?.intValue, count > 0 else {
            throw DLError.msg("Chrome sent an answer the app could not read")
        }
        let suggested = (meta["name"] as? String) ?? ""
        let type = (meta["type"] as? String) ?? ""
        let extPart = ext(url: URL(string: job.url) ?? URL(fileURLWithPath: "/"), contentType: type, disposition: suggested)
        let dest = uniqueURL(outDir(job).appendingPathComponent(Naming.base(job) + extPart))
        fm.createFile(atPath: dest.path, contents: nil)

        // 2. The pieces, written into place as they arrive.
        do {
            let fh = try FileHandle(forWritingTo: dest)
            defer { try? fh.close() }
            var pending = Set(0..<count)
            var written: Int64 = 0
            var lastBytes: Int64 = 0
            var lastTick = Date()
            while !pending.isEmpty {
                try Task.checkCancellation()
                var got = false
                for i in Array(pending) {
                    let raw = partsDir.appendingPathComponent("\(i).raw")
                    if fm.fileExists(atPath: raw.path) {
                        let data = try Data(contentsOf: raw)
                        try fh.seek(toOffset: UInt64(Int64(i) * chunk))
                        try fh.write(contentsOf: data)
                        try? fm.removeItem(at: raw)
                        written += Int64(data.count)
                        pending.remove(i)
                        got = true
                    }
                }
                if let why = failure() { throw DLError.msg(why) }
                if got { lastGot = Date() }
                else if Date().timeIntervalSince(lastGot) > 90 {
                    throw DLError.msg("Chrome stopped sending the file. Keep Chrome open with the Doddy extension on, then press retry.")
                }
                let now = Date()
                if now.timeIntervalSince(lastTick) >= 0.7 {
                    let rate = Double(written - lastBytes) / now.timeIntervalSince(lastTick)
                    progress(total > 0 ? min(0.99, Double(written) / Double(total)) : -1,
                             String(format: "%.2fMiB/s", rate / 1_048_576))
                    lastBytes = written
                    lastTick = now
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
        return dest
    }

    /// Direct media file with segmented download.
    static func file(_ job: Job, box: ResumeBox, progress: @escaping ProgressFn) async throws -> URL {
        guard let url = URL(string: job.url) else { throw DLError.msg("Bad URL") }
        let headers = job.headerFields

        // Continue a paused download: no new probe request (matters for single-use links).
        if let d = box.dest, box.ranged, !box.segs.isEmpty, FileManager.default.fileExists(atPath: d.path) {
            let again = RangedDownloader(url: url, headers: headers, dest: d, total: box.total,
                                         ranged: true, connections: 8, progress: progress, box: box)
            do { try await again.run() } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }   // URLSession reports a cancel as an error
                if !keepsPieces(error) { box.discard() }            // expired link or dropped connection: keep the pieces
                throw error
            }
            box.clear()
            if d.pathExtension.lowercased() == "ts" {
                progress(-1, "Converting to MP4…")
                return try await remuxToMP4(d)
            }
            return d
        }
        box.discard()   // nothing resumable: start clean

        // Probe: ask for 1 byte, see whether ranges are honoured and how big the file is.
        var probe = URLRequest(url: url)
        headers.forEach { probe.setValue($1, forHTTPHeaderField: $0) }
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        var total: Int64 = 0
        var ranged = false
        var ctype = ""
        var disp = ""
        var probeFailed = false
        var needBrowser = false
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: probe)
            bytes.task.cancel() // headers are enough; don't pull the body
            guard let http = resp as? HTTPURLResponse else { throw DLError.msg("No HTTP response") }
            if (200..<300).contains(http.statusCode) {
                if http.statusCode == 206,
                   let cr = http.value(forHTTPHeaderField: "Content-Range"),
                   let t = cr.split(separator: "/").last, let n = Int64(t) {
                    total = n
                    ranged = true
                } else {
                    total = http.expectedContentLength > 0 ? http.expectedContentLength : 0
                }
                ctype = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                disp = fileNameFromDisposition(http.value(forHTTPHeaderField: "Content-Disposition") ?? "")
            } else {
                // Some servers refuse the 1-byte range request (503, 403, 416...) but serve a plain GET.
                AppLog.write("probe answered HTTP \(http.statusCode); trying a plain download")
                probeFailed = true
                if http.statusCode == 401 || http.statusCode == 403 { needBrowser = true }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            probeFailed = true
        }

        // The site only answers a signed-in browser (Google Drive and similar): Chrome fetches the file for us.
        if needBrowser { return try await browserFile(job, progress: progress) }

        let name = Naming.base(job) + ext(url: url, contentType: ctype, disposition: disp)
        let dest = uniqueURL(outDir(job).appendingPathComponent(name))

        let useRanges = ranged && total > 2_000_000
        box.dest = dest
        box.total = total
        box.ranged = useRanges
        box.segs = []
        let dl = RangedDownloader(url: url, headers: headers, dest: dest, total: total,
                                  ranged: useRanges, connections: 8, progress: progress, box: box)
        do {
            try await dl.run()
        } catch is CancellationError {
            // Kept on purpose: the manager decides whether this was a pause or a cancel.
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if keepsPieces(error) && useRanges && !box.segs.isEmpty { throw error }   // keep the pieces: retry or "Refresh link" continues
            try? FileManager.default.removeItem(at: dest)
            box.clear()
            // Segmented download refused (rate limit / 503): one plain connection instead.
            if ranged && !probeFailed {
                AppLog.write("segmented download failed (\(error.localizedDescription)); retrying on one connection")
                // Still one ranged piece when the size is known, so Pause/Resume and retries continue
                // where they stopped instead of starting over (servers that refuse 8 connections, e.g. 429).
                let resumable = total > 0
                box.dest = dest
                box.total = total
                box.ranged = resumable
                box.segs = []
                let one = RangedDownloader(url: url, headers: headers, dest: dest, total: total,
                                           ranged: resumable, connections: 1, progress: progress,
                                           box: resumable ? box : nil)
                do { try await one.run() } catch is CancellationError {
                    throw CancellationError()   // a pause keeps the file and its progress
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    if resumable && keepsPieces(error) && !box.segs.isEmpty { throw error }
                    try? FileManager.default.removeItem(at: dest)
                    box.clear()
                    throw error
                }
            } else {
                throw error
            }
        }
        box.clear()
        if dest.pathExtension.lowercased() == "ts" {
            progress(-1, "Converting to MP4…")
            return try await remuxToMP4(dest)
        }
        return dest
    }

    /// Errors after which the pieces already on disk are worth keeping: an expired link (Refresh link continues)
    /// or a connection that dropped or stalled (retry continues). Big files should never start over for these.
    static func keepsPieces(_ error: Error) -> Bool {
        if linkExpired(error) { return true }
        if error.localizedDescription.contains("closed the connection early") { return true }
        if let u = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                    .dnsLookupFailed, .cannotFindHost, .resourceUnavailable].contains(u.code)
        }
        return false
    }

    /// The server no longer accepts this link (it expired, or needs a fresh one from the page).
    static func linkExpired(_ error: Error) -> Bool {
        let t = error.localizedDescription
        return ["HTTP 401", "HTTP 403", "HTTP 404", "HTTP 410"].contains { t.contains($0) }
    }

    /// MPEG-TS -> MP4 without re-encoding (fast, lossless). Keeps the .ts if ffmpeg is missing or fails.
    static func remuxToMP4(_ src: URL) async throws -> URL {
        guard let ff = Tools.find("ffmpeg") else { return src }
        let out = uniqueURL(src.deletingPathExtension().appendingPathExtension("mp4"))
        let status = try await Tools.run(ff, ["-y", "-i", src.path, "-c", "copy", out.path]) { _ in }
        if status == 0 {
            try? FileManager.default.removeItem(at: src)
            return out
        }
        try? FileManager.default.removeItem(at: out)
        return src
    }

    /// Converts a finished download to MP4, MP3 or M4A. Returns the new file, or the original if
    /// ffmpeg is missing, the file is not media, or the conversion fails.
    static func convert(_ src: URL, to format: String, deleteOriginal: Bool) async -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue,
              let ff = Tools.find("ffmpeg") else { return src }
        let media = ["mp4", "mkv", "webm", "mov", "avi", "flv", "ts", "m4v", "wmv", "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"]
        let ext = src.pathExtension.lowercased()
        guard media.contains(ext), ext != format else { return src }
        let audioOnlyInput = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"].contains(ext)
        if format == "mp4" && audioOnlyInput { return src }
        let args: [String]
        switch format {
        case "mp3": args = ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a": args = ["-vn", "-c:a", "aac", "-b:a", "192k"]
        default:    args = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
                            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        }
        let out = uniqueURL(src.deletingPathExtension().appendingPathExtension(format))
        let status = (try? await Tools.run(ff, ["-y", "-nostats", "-i", src.path] + args + [out.path]) { _ in }) ?? -1
        if status == 0 {
            if deleteOriginal { try? FileManager.default.removeItem(at: src) }
            return out
        }
        AppLog.write("convert to \(format) failed (code \(status)) for a .\(src.pathExtension) file")
        try? FileManager.default.removeItem(at: out)
        return src
    }

    /// yt-dlp announces each step after the download itself in square brackets. The list and the window both
    /// show it, so "Converting…" is never mistaken for "Getting started".
    static func ytStep(_ line: String) -> String? {
        let steps: [(String, String)] = [
            ("[Merger]", "Merging video and audio…"),
            ("[VideoConvertor]", "Converting…"), ("[VideoRemuxer]", "Converting…"),
            ("[ExtractAudio]", "Converting audio…"),
            ("[FixupM3u8]", "Fixing the file…"), ("[FixupM4a]", "Fixing the file…"), ("[FixupM4v]", "Fixing the file…"),
            ("[FixupTimestamp]", "Fixing the file…"), ("[FixupDuration]", "Fixing the file…"), ("[FixupStretched]", "Fixing the file…"),
            ("[EmbedSubtitle]", "Finishing up…"), ("[EmbedThumbnail]", "Finishing up…"), ("[Metadata]", "Finishing up…"),
        ]
        return steps.first(where: { line.hasPrefix($0.0) })?.1
    }

    /// HLS / DASH playlist via ffmpeg.
    static func stream(_ job: Job, progress: @escaping ProgressFn) async throws -> URL {
        guard let ff = Tools.find("ffmpeg") else {
            throw DLError.msg("ffmpeg is not installed. Open Doddy and use Setup to install it.")
        }
        let hdr = job.headerFields.map { "\($0.key): \($0.value)\r\n" }.joined()
        let dest = uniqueURL(outDir(job).appendingPathComponent(Naming.base(job) + ".mp4"))
        let args = ["-y", "-nostats", "-progress", "pipe:1", "-headers", hdr, "-i", job.url,
                    "-c", "copy", dest.path]
        let status = try await Tools.run(ff, args) { line in
            if line.hasPrefix("out_time=") {
                let t = String(line.dropFirst("out_time=".count)).prefix(8)
                progress(-1, "Recorded \(t)")
            }
        }
        if status != 0 {
            try? FileManager.default.removeItem(at: dest)
            throw DLError.msg("ffmpeg failed (code \(status))")
        }
        return dest
    }

    /// Whole page via yt-dlp (YouTube and hundreds of other sites).
    /// Retries once or twice with the fixes yt-dlp itself suggests.
    static func page(_ job: Job, box resumeBox: ResumeBox, progress: @escaping ProgressFn) async throws -> URL {
        guard let yt = Tools.find("yt-dlp") else {
            throw DLError.msg("yt-dlp is not installed. Open Doddy and use Setup to install it.")
        }
        // Unfinished pieces live in a hidden folder per download, so the downloads folder only ever
        // holds finished videos, and cancelling can remove them cleanly.
        let tmpDir = outDir(job).appendingPathComponent(
            ".doddy-tmp-" + stableHash((job.sourceUrl ?? job.pageUrl ?? job.url) + "|\(job.formatHeight ?? 0)|\(job.audioOnly == true)"),
            isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        resumeBox.dest = tmpDir
        resumeBox.ranged = false
        resumeBox.segs = []
        var base = ["--no-playlist", "--no-simulate", "--progress", "--newline",
                    "-P", outDir(job).path, "-P", "temp:" + tmpDir.path, "-o", Naming.ytdlp(job),
                    "--merge-output-format", "mp4", "-N", "8",
                    "--progress-template", "download:NM|%(progress._percent_str)s|%(progress._speed_str)s|%(progress.fragment_index)s|%(progress.fragment_count)s|%(info.playlist_index)s|%(info.n_entries)s",
                    "--print", "after_move:NMFILE|%(filepath)s"]
        if job.playlist == true {
            base = base.map { $0 == "--no-playlist" ? "--yes-playlist" : $0 }
            if let i = base.firstIndex(of: "-o"), i + 1 < base.count {
                base[i + 1] = "%(playlist_title|Playlist).80B/%(playlist_index)03d - " + base[i + 1]
            }
            base.append("--ignore-errors")
        }
        let limitKB = UserDefaults.standard.integer(forKey: "speedLimitKB")
        if limitKB > 0 { base += ["--limit-rate", "\(limitKB)K", "-N", "1"] }   // later -N wins: one thread so the cap is total
        let deno = Tools.find("deno")
        if let deno { base += ["--js-runtimes", "deno:\(deno)"] }
        if let ua = job.userAgent, !ua.isEmpty { base += ["--user-agent", ua] }
        if let l = job.acceptLanguage, !l.isEmpty { base += ["--add-header", "Accept-Language:\(l)"] }
        if job.chromeCookies ?? UserDefaults.standard.bool(forKey: "chromeCookies") { base += ["--cookies-from-browser", "chrome"] }
        if let c = job.cookies, !c.isEmpty { base += ["--add-header", "Cookie:\(c)"] }
        let target = job.sourceUrl ?? job.pageUrl ?? job.url
        if job.audioOnly == true {
            base += ["-f", "ba/b", "-x", "--audio-format", "mp3"]
        } else if let h = job.formatHeight {
            base += ["-f", "bv*[height<=\(h)]+ba/b[height<=\(h)]"]
        }
        if let r = job.referer, !r.isEmpty { base += ["--referer", r] }
        if UserDefaults.standard.bool(forKey: "subtitlesOn") && job.audioOnly != true {
            let langs = (UserDefaults.standard.string(forKey: "subtitleLangs") ?? "en").trimmingCharacters(in: .whitespaces)
            base += ["--write-subs", "--write-auto-subs", "--sub-langs", langs.isEmpty ? "en" : langs, "--convert-subs", "srt"]
        }

        // Fast mode for YouTube: many connections at once. Any problem falls back to the normal download below.
        if job.playlist != true, job.audioOnly != true, FastDownload.enabled(for: target) {
            let keep: Set<String> = ["--js-runtimes", "--user-agent", "--cookies-from-browser", "--add-header", "--referer", "-f"]
            var options: [String] = []
            var k = 0
            while k < base.count - 1 {
                if keep.contains(base[k]) { options += [base[k], base[k + 1]]; k += 2 } else { k += 1 }
            }
            do {
                if let out = try await FastDownload.download(job: job, yt: yt, target: target, options: options,
                                                             tmpDir: tmpDir, progress: progress) {
                    resumeBox.clear()
                    return out
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                AppLog.write("fast mode skipped: \(error.localizedDescription)")
            }
        }

        final class Box: @unchecked Sendable { var path: String?; var errors: [String] = [] }

        var extras: [String] = []
        var lastError = "yt-dlp failed"
        for _ in 0..<4 {
            let box = Box()
            let args = base + extras + [target]
            AppLog.write("yt-dlp run | site: \(target) | options: " + args.filter { $0.hasPrefix("-") }.joined(separator: " "))
            let status = try await Tools.run(yt, args) { line in
                // Only problems are logged; the other lines hold titles and file names.
                if line.hasPrefix("ERROR") || line.hasPrefix("WARNING") { AppLog.write(line) }
                if line.hasPrefix("ERROR") { box.errors.append(line) }
                if line.hasPrefix("["), let step = Downloaders.ytStep(line) { progress(-1, step) }
                if line.hasPrefix("NMFILE|") {
                    box.path = String(line.dropFirst("NMFILE|".count))
                } else if line.contains("NM|") {
                    let parts = line.components(separatedBy: "|")
                    if parts.count >= 3 {
                        var pct = Double(parts[1].replacingOccurrences(of: "%", with: "")
                            .trimmingCharacters(in: .whitespaces)).map { $0 / 100 }
                        var speed = parts[2].trimmingCharacters(in: .whitespaces)
                        // Long HLS videos report 0% for a long time; the part counter is the honest figure.
                        if parts.count >= 5,
                           let idx = Int(parts[3].trimmingCharacters(in: .whitespaces)),
                           let cnt = Int(parts[4].trimmingCharacters(in: .whitespaces)), cnt > 0 {
                            pct = min(1, Double(idx) / Double(cnt))
                            speed += "  ·  part \(idx)/\(cnt)"
                        }
                        // Playlists: spread the bar over all videos.
                        if parts.count >= 7,
                           let pi = Int(parts[5].trimmingCharacters(in: .whitespaces)),
                           let pn = Int(parts[6].trimmingCharacters(in: .whitespaces)), pn > 1 {
                            pct = (Double(pi - 1) + (pct ?? 0)) / Double(pn)
                            speed += "  ·  video \(pi)/\(pn)"
                        }
                        progress(pct ?? -1, speed)
                    }
                }
            }
            if status == 0 || (job.playlist == true && box.path != nil) {
                try? FileManager.default.removeItem(at: tmpDir)
                resumeBox.clear()
                if job.playlist == true, let p = box.path { return URL(fileURLWithPath: p).deletingLastPathComponent() }
                if let p = box.path { return URL(fileURLWithPath: p) }
                return Paths.downloads
            }
            let err = box.errors.last ?? "yt-dlp failed (code \(status))"
            lastError = String(err.prefix(220))

            if (err.contains("impersonate") || err.contains("Cloudflare")) && !extras.contains("generic:impersonate") {
                // Site blocks non-browser TLS fingerprints: ask yt-dlp to impersonate a browser.
                extras += ["--extractor-args", "generic:impersonate"]
                progress(-1, "Retrying with browser impersonation…")
                continue
            }
            if err.contains("INNERTUBE_CONTEXT") || err.contains("extractor error") {
                // YouTube sometimes breaks when logins or cookies are attached. Try without them, then another client.
                if base.contains("--cookies-from-browser") || base.contains(where: { $0.hasPrefix("Cookie:") }) {
                    var cleaned: [String] = []
                    var skip = false
                    for (i, x) in base.enumerated() {
                        if skip { skip = false; continue }
                        if x == "--cookies-from-browser" { skip = true; continue }
                        if x == "--add-header", i + 1 < base.count, base[i + 1].hasPrefix("Cookie:") { skip = true; continue }
                        cleaned.append(x)
                    }
                    base = cleaned
                    progress(-1, "Retrying without logins…")
                    continue
                }
                if !extras.contains("youtube:player_client=default,mweb") {
                    extras += ["--extractor-args", "youtube:player_client=default,mweb"]
                    progress(-1, "Retrying with another YouTube client…")
                    continue
                }
            }
            if err.contains("Requested format is not available") {
                if deno == nil {
                    lastError = "YouTube needs the Deno JavaScript runtime. Open Doddy Setup and install deno."
                    break
                }
                if !extras.contains("b/best") {
                    extras += ["-f", "b/best"]
                    progress(-1, "Retrying with a simpler format…")
                    continue
                }
            }
            break
        }
        throw DLError.msg(lastError)
    }
}
