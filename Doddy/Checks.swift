import Foundation

/// Small decisions about whether a download is the right file and whole, kept free of the app's other code
/// so `tools/test.sh` can test them on their own.
enum Checks {
    enum Verdict: Equatable {
        case same
        case changed(String)
    }

    /// Whether a resumed download still comes from the same file on the server.
    /// A different size always counts. A different ETag counts too, unless the server also says the file was
    /// last modified at the same time (mirrors behind one name often send different ETags for the same file).
    static func sameFile(knownETag: String?, newETag: String?,
                         knownModified: String?, newModified: String?,
                         knownTotal: Int64, newTotal: Int64?) -> Verdict {
        if let n = newTotal, n > 0, knownTotal > 0, n != knownTotal {
            return .changed("its size changed from \(size(knownTotal)) to \(size(n))")
        }
        if let a = clean(knownETag), let b = clean(newETag), a != b {
            if let m1 = knownModified, let m2 = newModified, m1 == m2 { return .same }
            return .changed("its version tag (ETag) changed")
        }
        if clean(knownETag) == nil || clean(newETag) == nil,
           let m1 = knownModified, let m2 = newModified, m1 != m2 {
            return .changed("its modified date changed")
        }
        return .same
    }

    /// An ETag without the weak marker and quotes, or nil when there is none.
    static func clean(_ etag: String?) -> String? {
        guard var e = etag?.trimmingCharacters(in: .whitespaces), !e.isEmpty else { return nil }
        if e.hasPrefix("W/") { e.removeFirst(2) }
        return e.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// The full size from a `Content-Range: bytes 0-0/12345` header.
    static func contentRangeTotal(_ header: String?) -> Int64? {
        guard let t = header?.split(separator: "/").last else { return nil }
        return Int64(t.trimmingCharacters(in: .whitespaces))
    }

    /// True when a file of `have` bytes is as big as the server said it would be (or no size was announced).
    static func isComplete(have: Int64, expected: Int64) -> Bool { expected <= 0 || have >= expected }

    /// Room for `needed` bytes plus a margin, or true when the free space cannot be read.
    static func hasRoom(needed: Int64, available: Int64?, margin: Int64 = 100_000_000) -> Bool {
        guard let available, needed > 0 else { return true }
        return available >= needed + margin
    }

    /// A pasted checksum as bare lowercase hex: spaces, "sha256:" and upper case are ignored.
    static func normalisedHash(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = t.range(of: ":") , t[..<r.lowerBound].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
            t = String(t[r.upperBound...])
        }
        return t.filter { !$0.isWhitespace }
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func size(_ n: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: n)
    }
}
