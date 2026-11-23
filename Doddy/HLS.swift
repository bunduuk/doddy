import Foundation
import CommonCrypto

/// Thrown when a playlist needs something this downloader does not do (DRM, separate audio, live...).
/// The caller then uses ffmpeg instead.
enum HLSFallback: Error { case needFFmpeg(String) }

func stableHash(_ s: String) -> String {
    var h: UInt64 = 14695981039346656037
    for b in s.utf8 { h ^= UInt64(b); h = h &* 1099511628211 }
    return String(h, radix: 16)
}

struct HLSSegment {
    var url: URL
    var index: Int
    var keyURL: URL?
    var iv: [UInt8]?
}

struct HLSVariant {
    var url: URL
    var bandwidth: Int
    var height: Int
    var audioGroup: String?
}

struct HLSPlaylist {
    var variants: [HLSVariant] = []
    var segments: [HLSSegment] = []
    var mapURL: URL?
    var ended = false
    var unsupported: String?
    var drm = false      // copy-protected (SAMPLE-AES, FairPlay, Widevine…): never downloaded
    var audioGroupsWithURI: Set<String> = []
}

/// Decides how fast the video parts are asked for: 8 at a time normally. When the site says "too many
/// requests", everyone pauses, then carries on with fewer at a time and a gap between requests.
/// After a run of good answers it speeds up again, a step at a time.
final class HLSThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let maxWidth: Int
    private var width: Int
    private var running = 0
    private var gap: TimeInterval = 0
    private var nextStart = Date.distantPast
    private var pauseUntil = Date.distantPast
    private var good = 0
    private var strikes = 0

    init(maxWidth: Int, start: Int, gap startGap: TimeInterval = 0) {
        self.maxWidth = maxWidth
        self.width = max(1, min(start, maxWidth))
        self.gap = startGap
    }

    /// nil: go ahead (a slot is taken). Otherwise: seconds to wait before asking again.
    private func tryTake() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let ready = max(nextStart, pauseUntil)
        if running < width, now >= ready {
            running += 1
            nextStart = now.addingTimeInterval(gap)
            return nil
        }
        return min(max(ready.timeIntervalSince(now), 0.05), 0.5)
    }

    func acquire() async throws {
        while let wait = tryTake() {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    func release() { lock.lock(); running = max(0, running - 1); lock.unlock() }

    /// A good answer. After a run of them, ask a little faster again.
    func succeeded() {
        lock.lock(); defer { lock.unlock() }
        strikes = 0
        good += 1
        if good >= 15 {
            good = 0
            if width < maxWidth { width += 1 }
            gap = gap < 0.2 ? 0 : gap / 2
        }
    }

    /// "Too many requests": everyone waits, and from now on fewer requests go out at once, further apart.
    /// Answers that were already on their way when a pause began belong to the same episode: they count once.
    func slowedDown(retryAfter: Int) -> (strikes: Int, pause: Double, width: Int, gap: TimeInterval, counted: Bool) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if now < pauseUntil { return (strikes, pauseUntil.timeIntervalSince(now), width, gap, false) }
        strikes += 1
        good = 0
        width = max(1, width / 2)
        gap = min(max(gap * 2, 0.5), 5)
        let pause = min(max(min(pow(2.0, Double(strikes)), 30), Double(retryAfter)), 120)
        pauseUntil = now.addingTimeInterval(pause)
        return (strikes, pause, width, gap, true)
    }
}

final class HLSCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var done = 0
    func add(bytes b: Int64) { lock.lock(); bytes += b; lock.unlock() }
    func finishOne() { lock.lock(); done += 1; lock.unlock() }
    func snapshot() -> (Int64, Int) { lock.lock(); defer { lock.unlock() }; return (bytes, done) }
}

private func hlsAttrs(_ s: String) -> [String: String] {
    var out: [String: String] = [:]
    var key = "", val = ""
    var inKey = true, inQuote = false
    func flush() {
        let k = key.trimmingCharacters(in: .whitespaces)
        if !k.isEmpty { out[k] = val.trimmingCharacters(in: .whitespaces) }
        key = ""; val = ""; inKey = true
    }
    for ch in s {
        if inQuote {
            if ch == "\"" { inQuote = false } else { val.append(ch) }
            continue
        }
        if ch == "\"" { inQuote = true; continue }
        if inKey {
            if ch == "=" { inKey = false } else { key.append(ch) }
        } else if ch == "," {
            flush()
        } else {
            val.append(ch)
        }
    }
    flush()
    return out
}

private func hexBytes(_ s: String) -> [UInt8]? {
    var h = s
    if h.lowercased().hasPrefix("0x") { h = String(h.dropFirst(2)) }
    if h.count % 2 == 1 { h = "0" + h }
    var out: [UInt8] = []
    var i = h.startIndex
    while i < h.endIndex {
        let j = h.index(i, offsetBy: 2)
        guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
        out.append(b)
        i = j
    }
    while out.count < 16 { out.insert(0, at: 0) }
    return out
}

func parseHLS(_ text: String, base: URL) -> HLSPlaylist {
    var pl = HLSPlaylist()
    var seq = 0
    var idx = 0
    var keyURL: URL?
    var keyIV: [UInt8]?
    var pending: [String: String]?

    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("#") {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                seq = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let a = hlsAttrs(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = (a["METHOD"] ?? "NONE").uppercased()
                if method == "NONE" {
                    keyURL = nil; keyIV = nil
                } else if method == "AES-128", let u = a["URI"], let ku = URL(string: u, relativeTo: base)?.absoluteURL {
                    keyURL = ku
                    keyIV = a["IV"].flatMap { hexBytes($0) }
                } else {
                    pl.unsupported = "encrypted with \(method)"
                    let fmt = (a["KEYFORMAT"] ?? "identity").lowercased()
                    if method.hasPrefix("SAMPLE-AES") || fmt != "identity" { pl.drm = true }
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let a = hlsAttrs(String(line.dropFirst("#EXT-X-MAP:".count)))
                if a["BYTERANGE"] != nil { pl.unsupported = "byte-range segments" }
                if let u = a["URI"] { pl.mapURL = URL(string: u, relativeTo: base)?.absoluteURL }
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = hlsAttrs(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = hlsAttrs(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                if (a["TYPE"] ?? "").uppercased() == "AUDIO", a["URI"] != nil, let g = a["GROUP-ID"] {
                    pl.audioGroupsWithURI.insert(g)
                }
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                pl.ended = true
            } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                pl.unsupported = "byte-range segments"
            }
            continue
        }
        guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
        if let a = pending {
            var h = 0
            if let r = a["RESOLUTION"], let hh = r.lowercased().split(separator: "x").last { h = Int(hh) ?? 0 }
            pl.variants.append(HLSVariant(url: url, bandwidth: Int(a["BANDWIDTH"] ?? "") ?? 0,
                                          height: h, audioGroup: a["AUDIO"]))
            pending = nil
        } else {
            var iv = keyIV
            if keyURL != nil && iv == nil {
                var n = UInt64(seq + idx)
                var bytes = [UInt8](repeating: 0, count: 16)
                var i = 15
                while n > 0 && i >= 0 { bytes[i] = UInt8(n & 0xff); n >>= 8; i -= 1 }
                iv = bytes
            }
            pl.segments.append(HLSSegment(url: url, index: idx, keyURL: keyURL, iv: iv))
            idx += 1
        }
    }
    return pl
}

private func aesDecrypt(_ data: Data, key: Data, iv: [UInt8]) throws -> Data {
    var out = Data(count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let outCapacity = out.count
    let status: CCCryptorStatus = out.withUnsafeMutableBytes { outPtr in
        data.withUnsafeBytes { inPtr in
            key.withUnsafeBytes { keyPtr in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyPtr.baseAddress, key.count, iv,
                        inPtr.baseAddress, data.count,
                        outPtr.baseAddress, outCapacity, &moved)
            }
        }
    }
    guard status == CCCryptorStatus(kCCSuccess) else { throw DLError.msg("Could not decrypt a video part (code \(status))") }
    out.count = moved
    return out
}

extension Downloaders {
    private static func fetchData(_ session: URLSession, _ url: URL, _ headers: [String: String], quiet: Bool = false) async throws -> Data {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await session.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            let hdr = { (n: String) in h.value(forHTTPHeaderField: n) ?? "-" }
            if h.statusCode == 429 {
                // Too many requests: say so once, remember it, and never pile more on.
                let first = RateGate.shared.hit(url.host ?? "", retryAfter: Int(hdr("Retry-After")))
                if !quiet && first { AppLog.write("   HTTP 429 (the site asks Doddy to slow down) | retry-after: \(hdr("Retry-After")) | server: \(hdr("Server")) | cf-ray: \(hdr("CF-RAY"))") }
                throw DLError.msg("Server answered HTTP 429")
            }
            let body = String(decoding: data.prefix(160), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
            if !quiet { AppLog.write("   HTTP \(h.statusCode) for \(url.absoluteString.prefix(140)) | server: \(hdr("Server")) | cf-ray: \(hdr("CF-RAY")) | cf-mitigated: \(hdr("cf-mitigated")) | body: \(body)") }
            throw DLError.msg("Server answered HTTP \(h.statusCode)")
        }
        return data
    }

    /// Other ways of introducing ourselves, tried when the first video part is refused.
    private static func headerVariants(_ base: [String: String], for url: URL) -> [[String: String]] {
        func origin(_ u: URL?) -> String? {
            guard let u, let sc = u.scheme, let h = u.host else { return nil }
            return "\(sc)://\(h)" + (u.port.map { ":\($0)" } ?? "")
        }
        var out: [[String: String]] = []
        if let o = origin(base["Referer"].flatMap { URL(string: $0) }) {
            var a = base; a["Referer"] = o + "/"; a["Origin"] = o; out.append(a)          // origin-only referer, as a browser sends cross-site
            var b = base; b.removeValue(forKey: "Origin"); out.append(b)                   // no Origin header
        }
        var c = base; c.removeValue(forKey: "Referer"); c.removeValue(forKey: "Origin"); out.append(c)   // neither
        if let o = origin(url) { var d = base; d["Referer"] = o + "/"; d["Origin"] = o; out.append(d) } // the CDN's own address
        return out
    }

    private static func fetchSegment(_ session: URLSession, _ s: HLSSegment, to file: URL,
                                     headers: [String: String], key: Data?, counter: HLSCounter,
                                     throttle: HLSThrottle) async throws {
        var last: Error?
        var fails = 0
        while true {
            try Task.checkCancellation()
            try await throttle.acquire()
            do {
                let fetched: Data
                do { fetched = try await fetchData(session, s.url, headers) }
                catch { throttle.release(); throw error }
                throttle.release()
                throttle.succeeded()
                var data = fetched
                let raw = Int64(data.count)
                if let key, let iv = s.iv { data = try aesDecrypt(data, key: key, iv: iv) }
                let tmp = file.appendingPathExtension("tmp")
                try data.write(to: tmp)
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: tmp, to: file)
                counter.add(bytes: raw)
                counter.finishOne()
                let wait = SpeedLimiter.shared.delay(forBytes: Int(raw))
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                last = error
                if RateGate.isRateLimit(error.localizedDescription) {
                    // The site wants fewer, slower requests: pause everyone, ask less often, and carry on.
                    let asked = RateGate.shared.retryAfter
                    let slow = throttle.slowedDown(retryAfter: asked)
                    if slow.counted {
                        RateGate.shared.learn(s.url.host ?? "", width: slow.width, gap: slow.gap)
                        AppLog.write("   the site asked to slow down: \(slow.width) at a time, \(String(format: "%.1f", slow.gap))s apart, pausing \(Int(slow.pause))s")
                        if asked > 120 || slow.strikes > 8 { throw error }   // still refused: the app waits longer, then tries again
                    }
                    continue
                }
                fails += 1
                if fails >= 3 { break }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        throw last ?? DLError.msg("A video part could not be downloaded")
    }

    /// Native HLS download: playlist parsed here, parts fetched 8 at a time into a hidden folder,
    /// joined and converted to MP4. Parts already on disk are skipped, so pause/resume and
    /// crash recovery just run this again.
    static func hls(_ job: Job, box: ResumeBox, progress: @escaping ProgressFn) async throws -> URL {
        guard let url = URL(string: job.url) else { throw DLError.msg("Bad URL") }
        if url.path.lowercased().hasSuffix(".mpd") { throw HLSFallback.needFFmpeg("DASH") }
        var headers = job.headerFields
        let fm = FileManager.default

        let dir = outDir(job).appendingPathComponent(".doddy-hls-" + (job.resumeKey ?? stableHash(job.url)), isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        box.dest = dir
        box.ranged = false
        box.segs = []

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        func fallback(_ why: String) -> Error {
            try? fm.removeItem(at: dir)
            box.clear()
            return HLSFallback.needFFmpeg(why)
        }

        do {
            // 1. The media playlist (cached on disk so a resume does not ask the server again).
            let cacheText = dir.appendingPathComponent("playlist.m3u8")
            let cacheBase = dir.appendingPathComponent("playlist.url")
            var playlist: HLSPlaylist
            if let t = try? String(contentsOf: cacheText, encoding: .utf8),
               let b = try? String(contentsOf: cacheBase, encoding: .utf8),
               let bu = URL(string: b) {
                playlist = parseHLS(t, base: bu)
            } else {
                progress(-1, "Reading playlist…")
                var text: String
                if let t = job.playlistText, t.contains("#EXTM3U") {
                    AppLog.write("   using the playlist Chrome read\(job.variantText == nil ? "" : " (+ quality playlist)")")
                    text = t   // read by Chrome; the server may not answer a second request
                } else {
                    AppLog.write("   no playlist from Chrome; asking the server")
                    text = String(decoding: try await fetchData(session, url, headers), as: UTF8.self)
                }
                var base = url
                var pl = parseHLS(text, base: base)
                if !pl.variants.isEmpty {
                    var pick: HLSVariant?
                    if let h = job.formatHeight {
                        pick = pl.variants.filter { $0.height > 0 && $0.height <= h }.max { $0.bandwidth < $1.bandwidth }
                    }
                    if pick == nil { pick = pl.variants.max { $0.bandwidth < $1.bandwidth } }
                    guard let v = pick else { throw fallback("no variant") }
                    if let g = v.audioGroup, pl.audioGroupsWithURI.contains(g) { throw fallback("separate audio track") }
                    base = v.url
                    if let vt = job.variantText, vt.contains("#EXTM3U"), job.variantUrl == v.url.absoluteString {
                        text = vt
                    } else {
                        text = String(decoding: try await fetchData(session, v.url, headers), as: UTF8.self)
                    }
                    pl = parseHLS(text, base: base)
                }
                try text.write(to: cacheText, atomically: true, encoding: .utf8)
                try base.absoluteString.write(to: cacheBase, atomically: true, encoding: .utf8)
                playlist = pl
            }
            if playlist.drm {
                try? fm.removeItem(at: dir)
                box.clear()
                throw DLError.msg("This video is copy-protected (DRM). Doddy does not download protected video.")
            }
            if let why = playlist.unsupported { throw fallback(why) }
            if !playlist.ended { throw fallback("live stream") }
            if playlist.segments.isEmpty { throw fallback("no parts found") }

            // 2. Keys (AES-128) and the init segment (fMP4).
            var keys: [URL: Data] = [:]
            for k in Set(playlist.segments.compactMap { $0.keyURL }) {
                if let b64 = job.keyData?[k.absoluteString] ?? job.keyData?.first(where: { URL(string: $0.key)?.path == k.path })?.value,
                   let d = Data(base64Encoded: b64) {
                    keys[k] = d   // read by Chrome
                } else {
                    keys[k] = try await fetchData(session, k, headers)
                }
            }
            let initFile = dir.appendingPathComponent("init.bin")
            if let m = playlist.mapURL, !fm.fileExists(atPath: initFile.path) {
                try await fetchData(session, m, headers).write(to: initFile)
            }

            // 3. The parts, 8 at a time. Finished ones are skipped.
            func partFile(_ s: HLSSegment) -> URL { dir.appendingPathComponent(String(format: "part%06d.bin", s.index)) }
            let total = playlist.segments.count
            let counter = HLSCounter()
            var todo: [HLSSegment] = []
            for s in playlist.segments {
                let f = partFile(s)
                if fm.fileExists(atPath: f.path) { counter.finishOne() } else { todo.append(s) }
            }

            let ticker = Task {
                var lastBytes: Int64 = 0
                var lastTime = Date()
                let fmt = ByteCountFormatter()
                fmt.countStyle = .file
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let (b, d) = counter.snapshot()
                    let now = Date()
                    let dt = now.timeIntervalSince(lastTime)
                    let bps = dt > 0 ? Double(b - lastBytes) / dt : 0
                    lastBytes = b
                    lastTime = now
                    progress(Double(d) / Double(total), fmt.string(fromByteCount: Int64(bps)) + "/s  ·  \(d)/\(total) parts")
                }
            }
            defer { ticker.cancel() }

            // Some servers answer only the browser. If the first part is refused, Chrome fetches them.
            var browserMode = false
            if let first = todo.first {
                do { _ = try await fetchData(session, first.url, headers) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    let m = error.localizedDescription
                    // Throttled: carry on, the workers pace themselves. A name the Mac cannot look up: Chrome may manage.
                    let dns = (error as? URLError).map { $0.code == .cannotFindHost || $0.code == .dnsLookupFailed } ?? false
                    if m.contains("HTTP 403") || m.contains("HTTP 401") || dns { browserMode = true }
                }
            }

            // Before involving Chrome, see whether the server just wants different headers.
            if browserMode, let first = todo.first {
                for (n, v) in headerVariants(headers, for: first.url).enumerated() {
                    do {
                        _ = try await fetchData(session, first.url, v, quiet: true)
                        headers = v
                        browserMode = false
                        AppLog.write("   the server accepts the app with header style \(n + 1)")
                        break
                    } catch is CancellationError { throw CancellationError() }
                    catch { continue }
                }
            }
            let finalHeaders = headers

            if browserMode {
                AppLog.write("   server refuses the app for the video parts (tried other header styles); asking Chrome to fetch \(todo.count) parts")
                progress(-1, "Waiting for Chrome…")
                let id = stableHash(job.url)
                let wantedDir = Paths.support.appendingPathComponent("wanted", isDirectory: true)
                let partsDir = Paths.support.appendingPathComponent("parts", isDirectory: true)
                    .appendingPathComponent(id, isDirectory: true)
                try? fm.removeItem(at: partsDir)
                try fm.createDirectory(at: wantedDir, withIntermediateDirectories: true)
                try fm.createDirectory(at: partsDir, withIntermediateDirectories: true)
                let reqFile = wantedDir.appendingPathComponent(id + ".json")
                var req: [String: Any] = ["id": id, "parts": todo.map { ["i": $0.index, "url": $0.url.absoluteString] as [String: Any] }]
                if let r = job.referer, !r.isEmpty { req["referer"] = r }
                if let l = job.acceptLanguage, !l.isEmpty { req["acceptLanguage"] = l }
                try JSONSerialization.data(withJSONObject: req).write(to: reqFile, options: .atomic)
                defer {
                    try? fm.removeItem(at: reqFile)
                    try? fm.removeItem(at: reqFile.appendingPathExtension("claimed"))
                    try? fm.removeItem(at: partsDir)
                }
                let byIndex = Dictionary(uniqueKeysWithValues: todo.map { ($0.index, $0) })
                var pending = Set(todo.map { $0.index })
                var lastGot = Date()
                while !pending.isEmpty {
                    try Task.checkCancellation()
                    var got = false
                    for i in Array(pending) {
                        let raw = partsDir.appendingPathComponent("\(i).raw")
                        let fail = partsDir.appendingPathComponent("\(i).fail")
                        if fm.fileExists(atPath: raw.path), let s = byIndex[i] {
                            var data = try Data(contentsOf: raw)
                            let size = Int64(data.count)
                            if let k = s.keyURL.flatMap({ keys[$0] }), let iv = s.iv { data = try aesDecrypt(data, key: k, iv: iv) }
                            try data.write(to: partFile(s), options: .atomic)
                            try? fm.removeItem(at: raw)
                            counter.add(bytes: size)
                            counter.finishOne()
                            pending.remove(i)
                            got = true
                        } else if fm.fileExists(atPath: fail.path) {
                            let why = (try? String(contentsOf: fail, encoding: .utf8)) ?? ""
                            throw DLError.msg("Chrome could not fetch a video part (\(why))")
                        }
                    }
                    if got { lastGot = Date() }
                    else if Date().timeIntervalSince(lastGot) > 90 {
                        throw DLError.msg("Chrome did not deliver the video. Keep the video's tab open with the Doddy extension on, then press retry.")
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            } else {
            // Starts at 4 at a time and works up to 8 while the answers are good; backs off when the site asks.
            let throttle = HLSThrottle(maxWidth: 8, start: RateGate.shared.width(for: todo.first?.url.host),
                                       gap: RateGate.shared.gap(for: todo.first?.url.host))
            try await withThrowingTaskGroup(of: Void.self) { group in
                var it = todo.makeIterator()
                func launch() -> Bool {
                    guard let s = it.next() else { return false }
                    let key = s.keyURL.flatMap { keys[$0] }
                    group.addTask {
                        try await fetchSegment(session, s, to: partFile(s), headers: finalHeaders, key: key, counter: counter, throttle: throttle)
                    }
                    return true
                }
                for _ in 0..<8 { if !launch() { break } }
                while try await group.next() != nil { _ = launch() }
            }
            }
            ticker.cancel()
            try Task.checkCancellation()

            // 4. Join the parts, then convert to MP4.
            progress(-1, "Joining parts…")
            let isFMP4 = playlist.mapURL != nil
            let joined = dir.appendingPathComponent(isFMP4 ? "all.mp4" : "all.ts")
            fm.createFile(atPath: joined.path, contents: nil)
            let out = try FileHandle(forWritingTo: joined)
            do {
                if isFMP4 { try out.write(contentsOf: try Data(contentsOf: initFile)) }
                for s in playlist.segments {
                    try Task.checkCancellation()
                    try out.write(contentsOf: try Data(contentsOf: partFile(s)))
                }
                try out.close()
            } catch {
                try? out.close()
                throw error
            }

            let name = Naming.base(job)
            let finalURL: URL
            if let ff = Tools.find("ffmpeg") {
                progress(-1, "Converting to MP4…")
                let target = uniqueURL(outDir(job).appendingPathComponent(name + ".mp4"))
                let status = try await Tools.run(ff, ["-y", "-i", joined.path, "-c", "copy", target.path]) { _ in }
                if status != 0 {
                    try? fm.removeItem(at: target)
                    throw DLError.msg("ffmpeg could not convert the video (code \(status)). The downloaded parts are kept; press retry.")
                }
                finalURL = target
            } else {
                let target = uniqueURL(outDir(job).appendingPathComponent(name + (isFMP4 ? ".mp4" : ".ts")))
                try fm.moveItem(at: joined, to: target)
                finalURL = target
            }
            try? fm.removeItem(at: dir)
            box.clear()
            return finalURL
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as HLSFallback {
            throw e
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // Nothing saved at all (it failed before the playlist): do not leave an empty folder behind.
            if ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty {
                try? fm.removeItem(at: dir)
                box.clear()
            }
            // The system's TLS stack refused this server (odd certificate or protocol). ffmpeg has its
            // own TLS code and often gets through, so hand over while nothing has been downloaded yet.
            if let u = error as? URLError,
               [.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected].contains(u.code),
               ((try? fm.contentsOfDirectory(atPath: dir.path))?.count ?? 0) <= 2 {
                throw fallback("TLS")
            }
            throw error
        }
    }
}
