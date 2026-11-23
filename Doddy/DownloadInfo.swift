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
