import Foundation
import AppKit

/// File names from the user's template: {title} {site} {date} {quality}.
enum Naming {
    static var template: String {
        let t = (UserDefaults.standard.string(forKey: "nameTemplate") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "{title}" : t
    }

    private static func site(_ job: Job) -> String {
        var h = URL(string: job.pageUrl ?? job.url)?.host ?? "web"
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    private static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Name without extension, for files Doddy writes itself.
    static func base(_ job: Job) -> String {
        var s = template.replacingOccurrences(of: "/", with: "-")
        s = s.replacingOccurrences(of: "{title}", with: safeName(job.title))
        s = s.replacingOccurrences(of: "{site}", with: site(job))
        s = s.replacingOccurrences(of: "{date}", with: today())
        let q = job.qualityLabel ?? (job.formatHeight.map { "\($0)p" } ?? "")
        s = s.replacingOccurrences(of: "{quality}", with: q)
        for empty in ["[]", "()", "{}"] { s = s.replacingOccurrences(of: empty, with: "") }
        s = s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return safeName(s)
    }

    /// The same template in yt-dlp's own syntax.
    static func ytdlp(_ job: Job) -> String {
        var s = template.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "%", with: "%%")
        if job.customName == true {
            s = s.replacingOccurrences(of: "{title}", with: safeName(job.title).replacingOccurrences(of: "%", with: "%%"))
        } else {
            s = s.replacingOccurrences(of: "{title}", with: "%(title).120B")
        }
        s = s.replacingOccurrences(of: "{site}", with: site(job).replacingOccurrences(of: "%", with: "%%"))
        s = s.replacingOccurrences(of: "{date}", with: today())
        s = s.replacingOccurrences(of: "{quality}", with: "%(height&{}p|)s")
        return s + ".%(ext)s"
    }

    // MARK: clean names

    private static let junkWords = "official|lyrics?|lyric video|audio|video|music video|hd|hq|4k|uhd|8k|1080p|720p|480p|360p|1440p|2160p|60fps|webrip|web-dl|bluray|brrip|x264|x265|hevc|h264|full hd|remastered|visualizer"
    private static let tlds = "com|net|org|tv|io|co|me|to|cc|xyz|info|site|live|video"

    /// "Song (Official Video) [1080p] - example.com" becomes "Song".
    static func cleaned(_ name: String) -> String {
        var s = name
        let patterns = [
            "\\s*[\\[\\(\\{][^\\]\\)\\}]*\\b(?:\(junkWords))\\b[^\\]\\)\\}]*[\\]\\)\\}]",
            "\\s*[-|–—•:]\\s*(?:www\\.)?[A-Za-z0-9-]+\\.(?:\(tlds))\\s*$",
            "\\s*[-|–—•]\\s*(?:YouTube|Vimeo|Dailymotion|Facebook|Twitter|TikTok|Instagram)\\s*$",
            "^\\s*(?:www\\.)?[A-Za-z0-9-]+\\.(?:\(tlds))\\s*[-|–—•:]\\s*",
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            }
        }
        s = s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .-_|–—•:"))
        return s.isEmpty ? name : s
    }

    /// Renames a finished file to its cleaned name. Returns the new location (or the old one).
    static func renameCleaned(_ file: URL) -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else { return file }
        let base = file.deletingPathExtension().lastPathComponent
        let new = cleaned(base)
        guard new != base else { return file }
        let dest = uniqueURL(file.deletingLastPathComponent().appendingPathComponent(new).appendingPathExtension(file.pathExtension))
        do { try FileManager.default.moveItem(at: file, to: dest); return dest } catch { return file }
    }
}
