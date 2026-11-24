import SwiftUI
import AppKit

/// Short forms of download addresses: signed links can carry tokens, so the full address is shown only on request.
enum AddressText {
    /// "https://cdn.site.com/a/b/video.mp4?token=…" becomes "https://cdn.site.com/…/video.mp4?…".
    static func short(_ s: String) -> String {
        guard let u = URL(string: s), let host = u.host else { return s }
        let name = u.lastPathComponent
        var tail = ""
        if !name.isEmpty && name != "/" { tail = (u.pathComponents.count > 2 ? "/…/" : "/") + name }
        let query = (u.query?.isEmpty == false) ? "?…" : ""
        return "\(u.scheme ?? "https")://\(host)\(tail)\(query)"
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// Whether finished downloads keep their address, referrer and page (Setup → Files).
    static var remember: Bool { UserDefaults.standard.object(forKey: "rememberAddresses") as? Bool ?? true }
}

extension Job {
    /// The same download without where it came from: only a short address stays, so the list still makes sense.
    func forgettingAddresses() -> Job {
        var j = self
        j.url = AddressText.short(url)
        j.referer = nil
        j.pageUrl = nil
        j.sourceUrl = nil
        j.mirrors = nil
        j.candidates = nil
        j.addressForgotten = true
        return j
    }
}

/// IDM-style download properties: where a download came from, each line with a copy button.
struct DownloadInfo: View {
    @ObservedObject var item: DownloadItem
    @State private var full = false

    private struct Line: Identifiable {
        let id: String, label: String, value: String, symbol: String, isPath: Bool
    }

    private var lines: [Line] {
        let j = item.job
        var out = [Line(id: "a", label: "Address", value: j.url, symbol: "link", isPath: false)]
        if let r = j.referer, !r.isEmpty {
            out.append(Line(id: "r", label: "Referrer", value: r, symbol: "arrow.uturn.backward", isPath: false))
        }
        if let p = j.pageUrl, !p.isEmpty, p != j.referer, p != j.url {
            out.append(Line(id: "p", label: "Page", value: p, symbol: "doc.richtext", isPath: false))
        }
        if let f = item.outputURL {
            out.append(Line(id: "f", label: "Saved as", value: f.path, symbol: "folder", isPath: true))
        }
        return out
    }

    /// Size of a file in bytes (0 when it is missing).
    static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    private struct Fact: Identifiable {
        let id: String, label: String, value: String, symbol: String, warn: Bool
    }

    /// Size, dates and whether the file is complete: what to look at when the same file was downloaded twice.
    private var facts: [Fact] {
        let fmt = ByteCountFormatter(); fmt.countStyle = .file
        let dateFmt = DateFormatter(); dateFmt.dateStyle = .medium; dateFmt.timeStyle = .medium
        var out: [Fact] = []
        let file = item.outputURL
        let exists = file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let onDisk = exists ? Self.size(of: file!) : 0
        let saved = onDisk > 0 ? onDisk : item.savedBytes
        let expected = item.expectedBytes > 0 ? item.expectedBytes : (item.job.sizeHint ?? 0)
        if item.state == .done {
            var text = saved > 0 ? fmt.string(fromByteCount: saved) : "unknown"
            var warn = false
            if !exists { text += " (file not found)"; warn = true }
            else if expected > 0 && saved > 0 {
                if saved >= expected { text += " of \(fmt.string(fromByteCount: expected)) · complete" }
                else if item.expectedBytes > 0 || saved * 100 < expected * 97 {
                    text += " of \(fmt.string(fromByteCount: expected)) · INCOMPLETE"; warn = true
                } else { text += " · size announced: \(fmt.string(fromByteCount: expected))" }
            } else { text += " · the site did not announce a size, so completeness cannot be checked" }
            out.append(Fact(id: "s", label: "Size", value: text, symbol: warn ? "exclamationmark.triangle" : "internaldrive", warn: warn))
        } else if expected > 0 {
            out.append(Fact(id: "s", label: "Size", value: fmt.string(fromByteCount: expected), symbol: "internaldrive", warn: false))
        }
        var added = item.addedAt
        var finished = item.finishedAt
        if item.state == .done, finished == nil, let f = file,
           let d = (try? FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate]) as? Date {
            finished = d   // older history: the file's own date
            if d < added { added = d }
        }
        out.append(Fact(id: "t", label: "Added", value: dateFmt.string(from: added), symbol: "calendar", warn: false))
        if let f = finished, item.state == .done {
            let secs = Int(f.timeIntervalSince(added))
            var took = ""
            if secs > 0 && secs < 86_400 * 3 {
                let h = secs / 3600, m = (secs % 3600) / 60
                took = " (took " + (h > 0 ? "\(h) h " : "") + "\(m) min \(secs % 60) s)"
            }
            out.append(Fact(id: "f", label: "Finished", value: dateFmt.string(from: f) + took, symbol: "checkmark.circle", warn: false))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Download details").font(.headline)
                Spacer()
                if item.job.addressForgotten != true {
                    Toggle("Full addresses", isOn: $full).toggleStyle(.switch).controlSize(.mini)
                        .help("Links can contain sign-in tokens; they are shortened unless you ask")
                }
            }
            ForEach(facts) { f in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: f.symbol).foregroundStyle(f.warn ? Color.orange : .secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(f.value).font(.system(size: 12, weight: f.warn ? .semibold : .regular))
                            .foregroundStyle(f.warn ? Color.orange : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }
            }
            Divider()
            ForEach(lines) { l in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: l.symbol).foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(full || l.isPath ? l.value : AddressText.short(l.value))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(full ? 6 : 1).truncationMode(.middle)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button { AddressText.copy(l.value) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy \(l.label.lowercased())")
                }
            }
            if item.job.addressForgotten == true {
                Text("The full address and referrer were not kept for this download (Setup → Files).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
