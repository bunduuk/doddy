import Foundation
import SwiftUI
import AppKit
import QuickLookThumbnailing
import AVFoundation

// MARK: - Thumbnails

enum ThumbCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>(); c.countLimit = 300; return c
    }()

    private static let failLock = NSLock()
    private static var failedAt: [String: Date] = [:]
    private static func recentlyFailed(_ path: String) -> Bool {
        failLock.lock(); defer { failLock.unlock() }
        return failedAt[path].map { Date().timeIntervalSince($0) < 600 } ?? false
    }
    private static func markFailed(_ path: String) {
        failLock.lock(); defer { failLock.unlock() }
        failedAt[path] = Date()
    }

    static func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url.path as NSString) { return hit }
        // A missing file, or one that failed lately (audio, odd format), is not retried on every scroll.
        guard FileManager.default.fileExists(atPath: url.path), !recentlyFailed(url.path) else { return nil }
        // A video that has only just finished can fail the first time, so try a few times.
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            if Task.isCancelled { return nil }
            if let img = await quickLook(url) { cache.setObject(img, forKey: url.path as NSString); return img }
            if let img = await frame(url) { cache.setObject(img, forKey: url.path as NSString); return img }
            if let img = await ffmpegFrame(url) { cache.setObject(img, forKey: url.path as NSString); return img }
        }
        markFailed(url.path)
        return nil
    }

    private static func quickLook(_ url: URL) async -> NSImage? {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 80), scale: 2,
                                               representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        return rep.nsImage
    }

    /// Last resort for formats macOS cannot decode (VP9, AV1, Opus): ask ffmpeg for one frame.
    private static func ffmpegFrame(_ url: URL) async -> NSImage? {
        guard let ff = Tools.find("ffmpeg") else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("doddy-thumb-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: out) }
        let status = try? await Tools.run(ff, ["-v", "error", "-y", "-ss", "1", "-i", url.path,
                                               "-frames:v", "1", "-vf", "scale=256:-2", out.path]) { _ in }
        guard status == 0, let data = try? Data(contentsOf: out) else { return nil }
        return NSImage(data: data)
    }

    /// Fallback: grab one frame from the video itself.
    private static func frame(_ url: URL) async -> NSImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 256, height: 160)
        guard let cg = try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// The picture of a finished video, in the list.
struct Thumb: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14)).foregroundStyle(.white, Theme.blue)
                .offset(x: 4, y: 4)
        }
        .task(id: url) { image = await ThumbCache.image(for: url) }
    }
}

// MARK: - Tidying leftovers

enum Maintenance {
    struct Leftover { let url: URL; let bytes: Int64 }

    private static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return total
    }

    /// Unfinished pieces that no download in the list is still using.
    @MainActor
    static func leftovers(manager: DownloadManager) -> [Leftover] {
        let fm = FileManager.default
        var roots: Set<String> = [Paths.downloads.path]
        if let p = UserDefaults.standard.string(forKey: "saveDir") { roots.insert(p) }
        for i in manager.items { roots.insert(i.saveDir.path) }

        // Items that may still continue: keep their pieces.
        var keep: [String] = []
        for i in manager.items where i.state != .done && i.state != .cancelled {
            if let d = i.resume.dest { keep.append(d.path) }
        }
        let partExts: Set<String> = ["part", "ytdl", "temp"]
        var found: [Leftover] = []
        for r in roots {
            let root = URL(fileURLWithPath: r, isDirectory: true)
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                        options: [], errorHandler: nil) else { continue }
            for case let u as URL in e {
                let name = u.lastPathComponent
                let isTmpDir = [".doddy-tmp-", ".doddy-hls-", ".neatmac-tmp-", ".neatmac-hls-"].contains { name.hasPrefix($0) }
                let isPart = partExts.contains(u.pathExtension.lowercased()) || name.contains(".part-Frag")
                if isTmpDir { e.skipDescendants() }
                guard isTmpDir || isPart else { continue }
                if keep.contains(where: { u.path == $0 || $0.hasPrefix(u.path + "/") || u.path.hasPrefix($0 + "/") }) { continue }
                found.append(Leftover(url: u, bytes: size(of: u)))
            }
        }
        return found
    }

    @MainActor
    static func tidy(manager: DownloadManager) {
        let list = leftovers(manager: manager)
        let a = NSAlert()
        if list.isEmpty {
            a.messageText = "Nothing to tidy"
            a.informativeText = "No leftovers from cancelled or broken downloads."
            a.addButton(withTitle: "OK")
            a.runModal()
            return
        }
        let total = list.reduce(Int64(0)) { $0 + $1.bytes }
        a.messageText = "Trash \(list.count) leftover item\(list.count == 1 ? "" : "s")?"
        a.informativeText = "\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) from cancelled or interrupted downloads. Finished files are safe."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for l in list { try? FileManager.default.trashItem(at: l.url, resultingItemURL: nil) }
    }
}

// MARK: - Stats

struct StatsView: View {
    @EnvironmentObject var manager: DownloadManager
    fileprivate struct SiteStat: Identifiable, Sendable { let id: String; var count: Int; var bytes: Int64 }
    @State private var monthBytes: Int64 = 0
    @State private var monthCount = 0
    @State private var allBytes: Int64 = 0
    @State private var allCount = 0
    @State private var sites: [SiteStat] = []

    private func fmt(_ b: Int64) -> String { b <= 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    private func compute() {
        // Read the file details away from the main thread, so the page never stutters.
        let input: [(URL, String)] = manager.items.compactMap { i in
            guard i.state == .done, let u = i.outputURL else { return nil }
            return (u, i.sourceHost)
        }
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let cal = Calendar.current
            var mb: Int64 = 0, mc = 0, ab: Int64 = 0, ac = 0
            var per: [String: SiteStat] = [:]
            for (u, host) in input {
                guard let attrs = try? fm.attributesOfItem(atPath: u.path) else { continue }
                var bytes = (attrs[.size] as? Int64) ?? 0
                if (attrs[.type] as? FileAttributeType) == .typeDirectory { bytes = 0 }
                let date = (attrs[.modificationDate] as? Date) ?? .distantPast
                ab += bytes; ac += 1
                if cal.isDate(date, equalTo: Date(), toGranularity: .month) { mb += bytes; mc += 1 }
                var h = host
                if h.hasPrefix("www.") { h.removeFirst(4) }
                var s = per[h] ?? SiteStat(id: h, count: 0, bytes: 0)
                s.count += 1; s.bytes += bytes
                per[h] = s
            }
            let top = per.values.sorted { $0.bytes > $1.bytes }.prefix(8).map { $0 }
            let (monthB, monthC, allB, allC) = (mb, mc, ab, ac)
            await MainActor.run {
                monthBytes = monthB; monthCount = monthC; allBytes = allB; allCount = allC; sites = top
            }
        }
    }

    var body: some View {
        GeometryReader { g in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Stats").font(.title2.weight(.semibold))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    StatTile(title: "Downloaded this month", value: fmt(monthBytes), symbol: "calendar", color: Theme.blue)
                    StatTile(title: "Videos this month", value: "\(monthCount)", symbol: "film", color: Theme.cyan)
                    StatTile(title: "Downloaded all time", value: fmt(allBytes), symbol: "internaldrive", color: Theme.violet)
                    StatTile(title: "Videos in total", value: "\(allCount)", symbol: "checkmark.circle", color: Theme.violet)
                }

                Text("Top sites").font(.headline)
                if sites.isEmpty {
                    Text("Finished downloads appear here.").foregroundStyle(.secondary)
                } else {
                    let top = max(sites.first?.bytes ?? 1, 1)
                    VStack(spacing: 10) {
                        ForEach(sites) { s in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(s.id).fontWeight(.medium)
                                    Spacer()
                                    Text("\(s.count) video\(s.count == 1 ? "" : "s") · \(fmt(s.bytes))")
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                                FunBar(value: Double(s.bytes) / Double(top), colors: [Theme.blue, Theme.violet, Theme.pink], height: 6)
                            }
                        }
                    }
                }
                Text("Based on files still on your Mac.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .glassCard(radius: 20)
            .frame(width: min(620, max(g.size.width - 48, 320)))
            .padding(24)
            .frame(width: g.size.width)
        }
        .scrollIndicators(.hidden)
        }
        .task(id: manager.items.count) { compute() }
    }
}

// MARK: - Speed graph

enum SpeedParse {
    /// "1.52MiB/s", "12.3 MB/s", "850KiB/s  ·  part 3/40" → bytes per second.
    static func bytesPerSecond(_ s: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*([KMGT]?)(?:i?)B/s", options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let nr = Range(m.range(at: 1), in: s), let ur = Range(m.range(at: 2), in: s),
              let n = Double(s[nr]) else { return nil }
        let mult: Double
        switch s[ur].uppercased() {
        case "K": mult = 1_000
        case "M": mult = 1_000_000
        case "G": mult = 1_000_000_000
        case "T": mult = 1_000_000_000_000
        default: mult = 1
        }
        return n * mult
    }
}

extension DownloadItem {
    /// Called with every progress update; keeps about one sample a second.
    func addSample(_ speedText: String) {
        let now = Date()
        guard now.timeIntervalSince(lastSample) >= 1, let v = SpeedParse.bytesPerSecond(speedText) else { return }
        lastSample = now
        // Smooth the readings: downloaders report speed in bursts, which would draw sharp spikes.
        let smoothed = history.last.map { $0 * 0.7 + v * 0.3 } ?? v
        history.append(smoothed)
        if history.count > 90 { history.removeFirst(history.count - 90) }
    }
}


// MARK: - Play while downloading

@MainActor
enum Preview {
    static func canPreview(_ item: DownloadItem) -> Bool {
        (item.state == .running || item.state == .paused) && item.resume.dest != nil
    }

    private static func player() -> URL? {
        for id in ["com.colliderli.iina", "org.videolan.vlc", "io.mpv"] {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u }
        }
        return nil
    }

    nonisolated private static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("doddy-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Opens what has been downloaded so far in a video player.
    static func open(_ item: DownloadItem) {
        guard let dest = item.resume.dest else { return }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dest.path, isDirectory: &isDir) else { return fail("The download has not started saving yet.") }
        // Earlier previews are not needed any more (a player that still has one open keeps reading it).
        for old in (try? fm.contentsOfDirectory(at: tempDir(), includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: old) }
        var file: URL?

        if isDir.boolValue, (dest.lastPathComponent.hasPrefix(".doddy-hls-") || dest.lastPathComponent.hasPrefix(".neatmac-hls-")) {
            // Joining the parts can take a while for a long video: done off the main thread.
            Task.detached(priority: .userInitiated) {
                let f = hlsPreview(dir: dest)
                await MainActor.run { show(f) }
            }
            return
        } else if isDir.boolValue {
            // yt-dlp: the biggest unfinished piece (the video stream) is usually playable on its own.
            func bytes(_ u: URL) -> Int64 { (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0 }
            let all = (try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)) ?? []
            let part = all.filter { $0.lastPathComponent.contains(".part") }.max { bytes($0) < bytes($1) }
            if let part {
                let link = tempDir().appendingPathComponent("Preview-" + UUID().uuidString.prefix(6) + ".mp4")
                try? fm.createSymbolicLink(at: link, withDestinationURL: part)
                file = link
            }
        } else if item.resume.ranged, let first = item.resume.segs.min(by: { $0[0] < $1[0] }), first[0] == 0, first[1] > 1_000_000 {
            // A file in several pieces: the start is complete up to where the first piece has got to.
            let out = tempDir().appendingPathComponent("Preview-" + UUID().uuidString.prefix(6) + "." + (dest.pathExtension.isEmpty ? "mp4" : dest.pathExtension))
            let length = first[1]
            // Copied in 8 MB steps off the main thread: the start can be hundreds of MB.
            Task.detached(priority: .userInitiated) {
                let f = copyStart(of: dest, length: length, to: out)
                await MainActor.run { show(f) }
            }
            return
        } else if ((try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0) > 1_000_000 {
            let link = tempDir().appendingPathComponent("Preview-" + UUID().uuidString.prefix(6) + "." + (dest.pathExtension.isEmpty ? "mp4" : dest.pathExtension))
            try? fm.createSymbolicLink(at: link, withDestinationURL: dest)
            file = link
        }

        show(file)
    }

    private static func show(_ file: URL?) {
        guard let f = file else { return fail("Not enough has been downloaded to play yet, or this kind of download cannot be played early.") }
        if let p = player() {
            NSWorkspace.shared.open([f], withApplicationAt: p, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(f)
        }
    }

    nonisolated private static func copyStart(of src: URL, length: Int64, to out: URL) -> URL? {
        guard FileManager.default.createFile(atPath: out.path, contents: nil),
              let r = try? FileHandle(forReadingFrom: src), let w = try? FileHandle(forWritingTo: out) else { return nil }
        defer { try? r.close(); try? w.close() }
        var left = length
        while left > 0 {
            guard let chunk = try? r.read(upToCount: Int(min(left, 8_388_608))), !chunk.isEmpty else { break }
            do { try w.write(contentsOf: chunk) } catch { return nil }
            left -= Int64(chunk.count)
        }
        return left < length ? out : nil
    }

    nonisolated private static func hlsPreview(dir: URL) -> URL? {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("part") && $0.hasSuffix(".bin") }.sorted()
        guard !names.isEmpty else { return nil }
        let initFile = dir.appendingPathComponent("init.bin")
        let hasInit = fm.fileExists(atPath: initFile.path)
        let out = tempDir().appendingPathComponent("Preview-" + UUID().uuidString.prefix(6) + (hasInit ? ".mp4" : ".ts"))
        fm.createFile(atPath: out.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: out) else { return nil }
        defer { try? h.close() }
        if hasInit, let d = try? Data(contentsOf: initFile) { try? h.write(contentsOf: d) }
        // Only the parts that follow each other from the start can be played.
        var expected = Int(names[0].dropFirst(4).dropLast(4)) ?? 0
        var written = 0
        for n in names {
            guard let idx = Int(n.dropFirst(4).dropLast(4)), idx == expected else { break }
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(n)) else { break }
            try? h.write(contentsOf: d)
            expected += 1; written += 1
        }
        return written > 0 ? out : nil
    }

    private static func fail(_ text: String) {
        let a = NSAlert()
        a.messageText = "Can't play yet"
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
