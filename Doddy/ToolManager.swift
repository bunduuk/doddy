import Foundation

/// Finds, installs and updates yt-dlp and ffmpeg inside the app's own folder
/// (~/Library/Application Support/Doddy/bin), so no Homebrew is needed.
@MainActor
final class ToolManager: ObservableObject {
    static let shared = ToolManager()

    @Published var ytdlpPath: String? = Tools.find("yt-dlp")
    @Published var ffmpegPath: String? = Tools.find("ffmpeg")
    @Published var denoPath: String? = Tools.find("deno")
    @Published var busy: Set<String> = []
    @Published var message: String = ""
    @Published var ytdlpVersion: String?
    @Published var ytdlpLatest: String?

    var updateAvailable: Bool {
        guard let v = ytdlpVersion, let l = ytdlpLatest else { return false }
        return l.compare(v, options: .numeric) == .orderedDescending
    }

    private var started = false

    func refresh() {
        ytdlpPath = Tools.find("yt-dlp")
        ffmpegPath = Tools.find("ffmpeg")
        denoPath = Tools.find("deno")
    }

    func isManaged(_ path: String?) -> Bool {
        guard let path else { return false }
        return path.hasPrefix(Paths.bin.path)
    }

    /// Called once at launch: installs whatever is missing.
    func installMissingOnce() async {
        guard !started else { return }
        started = true
        refresh()
        if ytdlpPath == nil { await install("yt-dlp") }
        if ffmpegPath == nil { await install("ffmpeg") }
        if denoPath == nil { await install("deno") }
        await checkVersions()
    }

    /// Reads the installed yt-dlp version and asks GitHub what the latest one is.
    func checkVersions() async {
        refresh()
        if let p = ytdlpPath {
            final class Out: @unchecked Sendable { var first = "" }
            let out = Out()
            _ = try? await Tools.run(p, ["--version"]) { if out.first.isEmpty { out.first = $0.trimmingCharacters(in: .whitespaces) } }
            ytdlpVersion = out.first.isEmpty ? nil : out.first
        } else {
            ytdlpVersion = nil
        }
        if let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tag = obj["tag_name"] as? String {
            ytdlpLatest = tag
        }
    }

    private func sourceURL(for name: String) -> URL {
        if name == "yt-dlp" {
            return URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
        }
        if name == "deno" {
            #if arch(arm64)
            let d = "aarch64"
            #else
            let d = "x86_64"
            #endif
            return URL(string: "https://github.com/denoland/deno/releases/latest/download/deno-\(d)-apple-darwin.zip")!
        }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        return URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.0/ffmpeg-darwin-\(arch)")!
    }

    private func works(_ path: String, _ arg: String) async -> Bool {
        let status = try? await Tools.run(path, [arg]) { _ in }
        return status == 0
    }

    func install(_ name: String) async {
        guard !busy.contains(name) else { return }
        busy.insert(name)
        message = "Downloading \(name)…"
        defer { busy.remove(name); refresh() }

        let dest = Paths.bin.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: Paths.bin, withIntermediateDirectories: true)
            let (tmp, resp) = try await URLSession.shared.download(from: sourceURL(for: name))
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw DLError.msg("Download failed (HTTP \(http.statusCode))")
            }
            try? FileManager.default.removeItem(at: dest)
            if name == "deno" {
                let zip = Paths.bin.appendingPathComponent("deno.zip")
                try? FileManager.default.removeItem(at: zip)
                try FileManager.default.moveItem(at: tmp, to: zip)
                let st = try await Tools.run("/usr/bin/unzip", ["-o", zip.path, "-d", Paths.bin.path]) { _ in }
                try? FileManager.default.removeItem(at: zip)
                if st != 0 { throw DLError.msg("could not unpack the download") }
            } else {
                try FileManager.default.moveItem(at: tmp, to: dest)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)

            message = "Checking \(name)…"
            let arg = name == "ffmpeg" ? "-version" : "--version"
            var ok = await works(dest.path, arg)
            if !ok && name == "ffmpeg" {
                // Unsigned binaries can be refused on Apple Silicon: sign ad hoc and retry.
                _ = try? await Tools.run("/usr/bin/codesign", ["--force", "--sign", "-", dest.path]) { _ in }
                ok = await works(dest.path, arg)
            }
            if !ok { throw DLError.msg("downloaded but would not start") }
            message = "\(name) installed"
            if name == "yt-dlp" { Task { await self.checkVersions() } }
        } catch {
            try? FileManager.default.removeItem(at: dest)
            message = "Could not install \(name): \(error.localizedDescription)"
        }
    }

    /// yt-dlp breaks when sites change; the standalone build can update itself.
    func updateYtDlp() async {
        guard let path = ytdlpPath, isManaged(path), !busy.contains("yt-dlp") else { return }
        busy.insert("yt-dlp")
        message = "Updating yt-dlp…"
        defer { busy.remove("yt-dlp"); refresh() }
        final class Last: @unchecked Sendable { var line = "" }
        let last = Last()
        _ = try? await Tools.run(path, ["-U"]) { last.line = $0 }
        message = last.line.isEmpty ? "yt-dlp update finished" : last.line
        await checkVersions()
    }
}
