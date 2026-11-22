import Foundation
import SwiftUI
import AppKit
#if canImport(Translation)
import Translation
#endif

/// Subtitles after the download: optional translation to English (on this Mac, with Apple's
/// Translation framework, macOS 15 or newer), then adding the subtitle files to the video.
enum Subtitles {
    private struct Block { var head: [String]; var text: String; var raw: String }

    /// Finds the .srt files yt-dlp saved next to the video, e.g. "Title.en.srt".
    static func sidecars(for video: URL) -> [URL] {
        let dir = video.deletingLastPathComponent()
        let base = video.deletingPathExtension().lastPathComponent
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension.lowercased() == "srt" && $0.lastPathComponent.hasPrefix(base + ".") }
                  .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func language(of srt: URL) -> String {
        let parts = srt.deletingPathExtension().lastPathComponent.split(separator: ".")
        return parts.last.map(String.init) ?? "und"
    }

    /// Main entry point. Always returns a usable file: the original video if anything goes wrong.
    @MainActor
    static func process(_ video: URL, translate: Bool, status: @escaping (String) -> Void) async -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: video.path, isDirectory: &isDir), !isDir.boolValue else { return video }
        var subs = sidecars(for: video)
        guard !subs.isEmpty else { return video }

        if translate, !subs.contains(where: { language(of: $0).lowercased().hasPrefix("en") }), let first = subs.first {
            status("Translating subtitles…")
            if let t = await translateToEnglish(first) { subs.append(t) }
        }

        let ext = video.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v", "mkv"].contains(ext), let ff = Tools.find("ffmpeg") else { return video }
        status("Adding subtitles…")
        let tmp = video.deletingLastPathComponent().appendingPathComponent(".doddy-subs-" + UUID().uuidString + "." + ext)
        var args = ["-y", "-nostats", "-i", video.path]
        for s in subs { args += ["-i", s.path] }
        args += ["-map", "0"]
        for i in subs.indices { args += ["-map", "\(i + 1)"] }
        args += ["-c", "copy", "-c:s", ext == "mkv" ? "srt" : "mov_text"]
        for (i, s) in subs.enumerated() { args += ["-metadata:s:s:\(i)", "language=\(language(of: s))"] }
        args.append(tmp.path)
        let code = (try? await Tools.run(ff, args) { _ in }) ?? -1
        // Swap in the new file in one step, so the video is never lost if something goes wrong half way.
        if code == 0, (try? FileManager.default.replaceItemAt(video, withItemAt: tmp)) != nil {
            for s in subs { try? FileManager.default.removeItem(at: s) }
        } else {
            AppLog.write("adding subtitles failed (code \(code)); leaving the .srt files next to the video")
            try? FileManager.default.removeItem(at: tmp)
        }
        return video
    }

    // MARK: SRT

    private static func parse(_ s: String) -> [Block] {
        let norm = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        return norm.components(separatedBy: "\n\n").compactMap { raw in
            let lines = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
            if lines.isEmpty { return nil }
            if lines.count >= 3 && lines[1].contains("-->") {
                return Block(head: Array(lines[0...1]), text: lines[2...].joined(separator: "\n"), raw: raw)
            }
            return Block(head: [], text: "", raw: raw)
        }
    }

    /// Returns "<name>.en.srt" next to the source, or nil when translation is not possible.
    @MainActor
    static func translateToEnglish(_ srt: URL) async -> URL? {
        guard let data = try? String(contentsOf: srt, encoding: .utf8) else { return nil }
        let blocks = parse(data)
        let texts = blocks.map { $0.text }
        guard texts.contains(where: { !$0.isEmpty }) else { return nil }
        guard let out = await translate(texts), out.count == blocks.count else { return nil }
        var result: [String] = []
        for (b, t) in zip(blocks, out) {
            result.append(b.head.isEmpty ? b.raw : (b.head + [t]).joined(separator: "\n"))
        }
        let name = srt.deletingPathExtension().deletingPathExtension().lastPathComponent
        let dest = srt.deletingLastPathComponent().appendingPathComponent(name + ".en.srt")
        do { try (result.joined(separator: "\n\n") + "\n").write(to: dest, atomically: true, encoding: .utf8) } catch { return nil }
        return dest
    }

    // MARK: Apple Translation (needs a SwiftUI view to host the session)

    @MainActor
    static func translate(_ texts: [String]) async -> [String]? {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            return await withCheckedContinuation { (cont: CheckedContinuation<[String]?, Never>) in
                let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                                   styleMask: [.titled], backing: .buffered, defer: false)
                win.title = "Doddy"
                win.isReleasedWhenClosed = false
                let once = Once()
                let finish: ([String]?) -> Void = { r in
                    DispatchQueue.main.async {
                        guard once.first() else { return }
                        win.close()
                        cont.resume(returning: r)
                    }
                }
                win.contentView = NSHostingView(rootView: TranslateHost(texts: texts, done: finish))
                win.center()
                win.makeKeyAndOrderFront(nil)
                // If macOS never answers (a language download declined, for instance), do not hold the download forever.
                DispatchQueue.main.asyncAfter(deadline: .now() + 180) { finish(nil) }
            }
        }
        #endif
        return nil
    }

    private final class Once {
        private var used = false
        func first() -> Bool { if used { return false }; used = true; return true }
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct TranslateHost: View {
    let texts: [String]
    let done: ([String]?) -> Void
    @State private var config: TranslationSession.Configuration? =
        TranslationSession.Configuration(source: nil, target: Locale.Language(identifier: "en"))

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Translating subtitles…").font(.callout)
            Text("macOS may download a language first.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 340)
        .translationTask(config) { session in
            do {
                let reqs = texts.enumerated().map {
                    TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                }
                let res = try await session.translations(from: reqs)
                var out = texts
                for r in res { if let id = r.clientIdentifier, let i = Int(id), i < out.count { out[i] = r.targetText } }
                done(out)
            } catch {
                AppLog.write("subtitle translation failed: \(error.localizedDescription)")
                done(nil)
            }
        }
    }
}
#endif
