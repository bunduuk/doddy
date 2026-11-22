import Foundation

/// "Fast YouTube": takes the direct stream links from yt-dlp, downloads them with many connections at once
/// (YouTube limits every single connection), then joins video and audio with ffmpeg.
/// Returns nil whenever anything is unusual, and the normal yt-dlp download takes over.
enum FastDownload {
    struct Stream {
        let url: URL
        let headers: [String: String]
        let ext: String
        var size: Int64
    }

    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var n: Int64 = 0
        func add(_ k: Int64) { lock.lock(); n += k; lock.unlock() }
        var value: Int64 { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Hands out chunk numbers to the workers, one at a time.
    actor Dispenser {
        private var next = 0
        private let count: Int
        init(count: Int) { self.count = count }
        func take() -> Int? {
            guard next < count else { return nil }
            let i = next
            next += 1
            return i
        }
    }

    static func enabled(for target: String) -> Bool {
        guard (UserDefaults.standard.object(forKey: "fastYouTube") as? Bool) ?? true else { return false }
        guard let h = URL(string: target)?.host?.lowercased() else { return false }
        return h.hasSuffix("youtube.com") || h == "youtu.be" || h.hasSuffix("youtube-nocookie.com")
    }

    /// Asks yt-dlp for the direct links only. Nothing is downloaded here.
    static func streams(yt: String, target: String, options: [String]) async throws -> (title: String, streams: [Stream])? {
        final class Out: @unchecked Sendable { var json = "" }
        let out = Out()
        let args = ["--no-playlist", "--no-warnings", "-J"] + options + [target]
        let status = try await Tools.run(yt, args) { line in
            if line.hasPrefix("{") && line.count > out.json.count { out.json = line }
        }
        guard status == 0, let data = out.json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let formats = (root["requested_formats"] as? [[String: Any]]) ?? [root]
        var result: [Stream] = []
        for f in formats {
            guard let u = f["url"] as? String, let url = URL(string: u) else { return nil }
            let proto = (f["protocol"] as? String) ?? "https"
            guard proto == "https" || proto == "http" else { return nil }     // not a piece-by-piece stream
            var h = (f["http_headers"] as? [String: String]) ?? [:]
            h["Accept-Encoding"] = "identity"
            let ext = (f["ext"] as? String) ?? "mp4"
            result.append(Stream(url: url, headers: h, ext: ext, size: 0))
        }
        guard !result.isEmpty, result.count <= 2 else { return nil }
        return ((root["title"] as? String) ?? "", result)
    }

    /// The real size, from a one-byte range request.
    static func probeSize(_ s: Stream) async -> Int64? {
        var req = URLRequest(url: s.url)
        s.headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 206,
              let cr = http.value(forHTTPHeaderField: "Content-Range"),
              let t = cr.split(separator: "/").last, let n = Int64(t) else { return nil }
        return n
    }

    /// Downloads one stream in 10 MB pieces over 8 connections.
    static func fetch(_ s: Stream, to dest: URL, tally: Tally) async throws {
        let chunk: Int64 = 10_485_760
        let workers = 8
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let fh = try FileHandle(forWritingTo: dest)
        defer { try? fh.close() }
        try fh.truncate(atOffset: UInt64(s.size))
        let fd = fh.fileDescriptor
        let count = Int((s.size + chunk - 1) / chunk)
        let queue = Dispenser(count: count)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = workers
        cfg.timeoutIntervalForRequest = 45
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<min(workers, count) {
                group.addTask {
                    while let i = await queue.take() {
                        let start = Int64(i) * chunk
                        let end = min(s.size - 1, start + chunk - 1)
                        var attempt = 0
                        while true {
                            do {
                                var req = URLRequest(url: s.url)
                                s.headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
                                req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                                let (data, resp) = try await session.data(for: req)
                                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                                guard code == 206, Int64(data.count) == end - start + 1 else {
                                    throw DLError.msg("HTTP \(code)")
                                }
                                let wrote = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, off_t(start)) }
                                guard wrote == data.count else { throw DLError.msg("Could not write the file") }
                                tally.add(Int64(data.count))
                                break
                            } catch {
                                if Task.isCancelled { throw CancellationError() }
                                attempt += 1
                                let t = error.localizedDescription
                                if attempt >= 3 || t.contains("HTTP 403") || t.contains("HTTP 410") { throw error }
                                try await Task.sleep(nanoseconds: 700_000_000)
                            }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    static func download(job: Job, yt: String, target: String, options: [String], tmpDir: URL,
                         progress: @escaping ProgressFn) async throws -> URL? {
        progress(-1, "Preparing fast download…")
        guard let found = try await streams(yt: yt, target: target, options: options) else { return nil }
        var list = found.streams
        for i in list.indices {
            guard let n = await probeSize(list[i]), n > 1_000_000 else { return nil }
            list[i].size = n
        }
        let total = max(list.reduce(Int64(0)) { $0 + $1.size }, 1)
        let tally = Tally()
        let ticker = Task.detached {
            var lastB = tally.value
            var lastT = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                let b = tally.value, t = Date()
                let rate = Double(b - lastB) / max(t.timeIntervalSince(lastT), 0.001)
                lastB = b; lastT = t
                progress(min(0.98, Double(b) / Double(total)), String(format: "%.2fMiB/s", rate / 1_048_576))
            }
        }
        defer { ticker.cancel() }

        var files: [URL] = []
        do {
            for (i, s) in list.enumerated() {
                let f = tmpDir.appendingPathComponent("fast\(i).\(s.ext)")
                files.append(f)
                try await fetch(s, to: f, tally: tally)
            }
        } catch is CancellationError {
            files.forEach { try? FileManager.default.removeItem(at: $0) }
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            AppLog.write("fast download failed: \(error.localizedDescription)")
            files.forEach { try? FileManager.default.removeItem(at: $0) }
            return nil
        }
        ticker.cancel()

        guard let ff = Tools.find("ffmpeg") else { return nil }
        progress(0.99, "Merging…")
        var named = job
        if job.customName != true, !found.title.isEmpty { named.title = found.title }
        let out = uniqueURL(Downloaders.outDir(job).appendingPathComponent(Naming.base(named) + ".mp4"))
        var args = ["-y", "-nostats", "-loglevel", "error"]
        files.forEach { args += ["-i", $0.path] }
        args += ["-c", "copy", "-strict", "-2", "-movflags", "+faststart", out.path]
        let status = try await Tools.run(ff, args) { _ in }
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        guard status == 0 else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        try? FileManager.default.removeItem(at: tmpDir)
        return out
    }
}
