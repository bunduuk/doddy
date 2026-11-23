import Foundation
import UserNotifications
import AppKit

enum Installer {
    static let extensionID = "lmlggkipmfmhpblpcnkiocnhkadljanb"
    static let hostName = "io.github.bunduuk.doddy.host"
    static let oldHostNames = ["com.neatmac.host"]   // earlier builds: still answered, so an extension not reloaded keeps working

    static let browserDirs = [
        "Google/Chrome", "Google/Chrome Beta", "Chromium",
        "BraveSoftware/Brave-Browser", "Microsoft Edge", "Vivaldi", "Arc/User Data",
    ]

    static var appSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static func installedBrowsers() -> [String] {
        browserDirs.filter {
            FileManager.default.fileExists(atPath: appSupportRoot.appendingPathComponent($0).path)
        }
    }

    /// Writes the wrapper script + native messaging manifests. Safe to call on every launch,
    /// so the manifests always point at wherever the app currently lives.
    @discardableResult
    static func registerHost() -> Int {
        let fm = FileManager.default
        guard let exe = Bundle.main.executablePath else { return 0 }

        let script = "#!/bin/bash\nexec \"\(exe)\" --host\n"
        try? script.write(to: Paths.hostScript, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.hostScript.path)

        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Doddy download helper",
            "path": Paths.hostScript.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) else { return 0 }

        var count = 0
        for b in installedBrowsers() {
            let dir = appSupportRoot.appendingPathComponent(b).appendingPathComponent("NativeMessagingHosts")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(hostName).json")
            for old in oldHostNames {
                var legacy = manifest
                legacy["name"] = old
                if let d = try? JSONSerialization.data(withJSONObject: legacy, options: [.prettyPrinted]) {
                    try? d.write(to: dir.appendingPathComponent("\(old).json"), options: .atomic)
                }
            }
            if (try? data.write(to: file, options: .atomic)) != nil { count += 1 }
        }
        return count
    }

    static func helperRegistered() -> Bool {
        installedBrowsers().contains {
            FileManager.default.fileExists(atPath: appSupportRoot.appendingPathComponent($0)
                .appendingPathComponent("NativeMessagingHosts/\(hostName).json").path)
        }
    }

    /// Copies the bundled extension to a stable place and returns it.
    @discardableResult
    static func prepareExtensionFolder() -> URL? {
        let fm = FileManager.default
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("extension") else { return nil }
        try? fm.removeItem(at: Paths.extensionDir)
        do { try fm.copyItem(at: src, to: Paths.extensionDir) } catch { return nil }
        return Paths.extensionDir
    }

    static func revealExtensionFolder() {
        if let dir = prepareExtensionFolder() {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    static func openChromeExtensionsPage() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Google Chrome", "chrome://extensions"]
        try? p.run()
    }
}

/// Runs when Chrome starts the binary with --host. Reads one message, queues the job
/// for the main app, makes sure the app is running, replies, exits.
enum HostMode {
    static func run() -> Never {
        let input = FileHandle.standardInput
        let lenData = input.readData(ofLength: 4)
        guard lenData.count == 4 else { exit(0) }
        let len = lenData.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        let body = input.readData(ofLength: Int(len))

        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let action = obj?["action"] as? String
        // The extension talked to us at least once: the setup tour can show it as connected.
        try? "\(Date().timeIntervalSince1970)".write(to: Paths.support.appendingPathComponent("extension-seen"),
                                                   atomically: true, encoding: .utf8)

        switch action {
        case "ping":
            reply(["ok": true, "message": "pong"])
        case "download":
            try? FileManager.default.createDirectory(at: Paths.queue, withIntermediateDirectories: true)
            let file = Paths.queue.appendingPathComponent("\(UUID().uuidString).json")
            do {
                try body.write(to: file, options: .atomic)
                launchMainApp()
                reply(["ok": true, "message": "Doddy"])
            } catch {
                reply(["ok": false, "error": "Could not queue job: \(error.localizedDescription)"])
            }
        case "formats":
            reply(remoteFormats(body))
        case "wanted":
            reply(takeWanted())
        case "refreshWanted":
            reply(refreshWanted())
        case "part":
            reply(savePart(obj ?? [:]))
        default:
            reply(["ok": false, "error": "unknown action"])
        }
        exit(0)
    }

    // MARK: quality listing (runs yt-dlp -J and replies with a short summary)

    private final class Capture: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }

    private static func runJSON(_ yt: String, url: String, referer: String?, ua: String?,
                                cookies: String?, timeout: Double = 20) -> (json: [String: Any]?, error: String) {
        var args = ["-J", "--no-playlist", "--no-warnings"]
        if let deno = Tools.find("deno") { args += ["--js-runtimes", "deno:\(deno)"] }
        if let ua, !ua.isEmpty { args += ["--user-agent", ua] }
        if UserDefaults.standard.bool(forKey: "chromeCookies") { args += ["--cookies-from-browser", "chrome"] }
        if let r = referer, !r.isEmpty { args += ["--referer", r] }
        if let c = cookies, !c.isEmpty { args += ["--add-header", "Cookie:\(c)"] }
        args.append(url)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: yt)
        p.arguments = args
        p.environment = Tools.environment
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        let cap = Capture()
        let group = DispatchGroup()
        do { try p.run() } catch { return (nil, error.localizedDescription) }
        group.enter()
        DispatchQueue.global().async { cap.out = o.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { cap.err = e.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return (nil, "yt-dlp took too long")
        }
        p.waitUntilExit()
        if p.terminationStatus == 0,
           let obj = try? JSONSerialization.jsonObject(with: cap.out) as? [String: Any] {
            return (obj, "")
        }
        let lines = (String(data: cap.err, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        let line = lines.last(where: { $0.hasPrefix("ERROR") }) ?? lines.last ?? "yt-dlp failed"
        return (nil, String(line.prefix(220)))
    }

    /// Video heights with the best bitrate/size for each, or nil when there are none.
    private static func qualities(_ json: [String: Any]) -> [[String: Any]]? {
        var best: [Int: (tbr: Double, size: Int64)] = [:]
        for f in (json["formats"] as? [[String: Any]]) ?? [] {
            guard let h = (f["height"] as? NSNumber)?.intValue, h > 0,
                  (f["vcodec"] as? String) != "none" else { continue }
            let tbr = (f["tbr"] as? NSNumber)?.doubleValue ?? 0
            let size = (f["filesize"] as? NSNumber)?.int64Value
                ?? (f["filesize_approx"] as? NSNumber)?.int64Value ?? 0
            if best[h] == nil || tbr > best[h]!.tbr { best[h] = (tbr, size) }
        }
        if best.isEmpty { return nil }
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return best.keys.sorted(by: >).map { h in
            let sz = best[h]!.size
            let label = "\(h)p" + (sz > 0 ? " · ~" + fmt.string(fromByteCount: sz) : "")
            return ["height": h, "label": label]
        }
    }

    /// Checks the page and every detected stream at the same time (each capped at 20 s),
    /// then uses the first source, in order of preference, that gave a quality list.
    static func listFormats(_ obj: [String: Any]) -> [String: Any] {
        guard let yt = Tools.find("yt-dlp") else {
            return ["ok": false, "error": "yt-dlp is not installed. Open Doddy once so it can install it."]
        }
        let pageUrl = (obj["pageUrl"] as? String) ?? (obj["url"] as? String) ?? ""
        let ua = obj["userAgent"] as? String

        // YouTube: listing every format makes yt-dlp solve YouTube's JavaScript challenges
        // (20 s or more). Downloading with a height limit works without that lookup, so
        // offer the standard heights straight away; yt-dlp picks the best match at download time.
        if let host = URL(string: pageUrl)?.host?.lowercased(),
           host.hasSuffix("youtube.com") || host == "youtu.be" || host.hasSuffix("youtube-nocookie.com") {
            let heights = [2160, 1440, 1080, 720, 480, 360, 240]
            return ["ok": true, "title": "",
                    "source": ["url": pageUrl, "kind": "page", "referer": pageUrl],
                    "formats": heights.map { ["height": $0, "label": "\($0)p"] as [String: Any] }]
        }

        var sources: [(url: String, kind: String, referer: String?, ua: String?, cookies: String?)] = []
        sources.append((pageUrl, "page", (obj["referer"] as? String) ?? pageUrl, ua, obj["cookies"] as? String))
        for c in ((obj["candidates"] as? [[String: Any]]) ?? []).prefix(3) {
            if let u = c["url"] as? String {
                sources.append((u, (c["kind"] as? String) ?? "file", c["referer"] as? String,
                                (c["userAgent"] as? String) ?? ua, c["cookies"] as? String))
            }
        }

        final class Slot: @unchecked Sendable {
            var json: [String: Any]?
            var error = ""
        }
        let slots = sources.map { _ in Slot() }
        let group = DispatchGroup()
        for (i, s) in sources.enumerated() where !s.url.isEmpty {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let r = runJSON(yt, url: s.url, referer: s.referer, ua: s.ua, cookies: s.cookies, timeout: 20)
                slots[i].json = r.json
                slots[i].error = r.error
                group.leave()
            }
        }
        group.wait()

        var lastError = "No downloadable video found"
        for (i, s) in sources.enumerated() {
            if let json = slots[i].json, let list = qualities(json) {
                return ["ok": true,
                        "title": (json["title"] as? String) ?? "",
                        "source": ["url": s.url, "kind": s.kind, "referer": s.referer ?? ""],
                        "formats": list]
            }
            if !slots[i].error.isEmpty { lastError = slots[i].error }
        }
        return ["ok": false, "error": lastError]
    }

    /// yt-dlp must not run as a child of Chrome (macOS quarantines what it unpacks and
    /// reports "Python.framework is damaged"). So hand the request to the main app via
    /// a file, wait for its answer file, and relay it.
    private static func remoteFormats(_ body: Data) -> [String: Any] {
        let id = UUID().uuidString
        let dir = Paths.support.appendingPathComponent("rpc", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let req = dir.appendingPathComponent("\(id).req.json")
        let res = dir.appendingPathComponent("\(id).res.json")
        do { try body.write(to: req, options: .atomic) } catch {
            return ["ok": false, "error": "Could not contact Doddy: \(error.localizedDescription)"]
        }
        launchMainApp()
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if let data = try? Data(contentsOf: res),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                try? FileManager.default.removeItem(at: res)
                return obj
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        try? FileManager.default.removeItem(at: req)
        return ["ok": false, "error": "Doddy did not answer in time"]
    }

    // MARK: parts fetched by Chrome (for servers that only answer the browser itself)

    /// Hands the extension the lists of video parts the app wants Chrome to fetch.
    private static func takeWanted() -> [String: Any] {
        let fm = FileManager.default
        let dir = Paths.support.appendingPathComponent("wanted", isDirectory: true)
        var out: [[String: Any]] = []
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                out.append(o)
            }
            try? fm.moveItem(at: f, to: f.appendingPathExtension("claimed"))
        }
        return ["ok": true, "wanted": out]
    }

    /// Downloads waiting for a new link. They stay until the app has received one.
    private static func refreshWanted() -> [String: Any] {
        let dir = Paths.support.appendingPathComponent("refresh", isDirectory: true)
        var out: [[String: Any]] = []
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { out.append(o) }
        }
        return ["ok": true, "refresh": out]
    }

    /// Stores one part (or a failure note) sent by the extension for the app to pick up.
    private static func savePart(_ obj: [String: Any]) -> [String: Any] {
        guard let id = obj["id"] as? String, let index = obj["index"] as? Int,
              !id.contains("/"), !id.contains("..") else { return ["ok": false, "error": "bad part"] }
        let fm = FileManager.default
        let dir = Paths.support.appendingPathComponent("parts", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let err = obj["error"] as? String {
            try? err.write(to: dir.appendingPathComponent("\(index).fail"), atomically: true, encoding: .utf8)
            return ["ok": true]
        }
        guard let b64 = obj["data"] as? String, let data = Data(base64Encoded: b64) else {
            return ["ok": false, "error": "no data"]
        }
        let tmp = dir.appendingPathComponent("\(index).tmp")
        do {
            try data.write(to: tmp)
            let dst = dir.appendingPathComponent("\(index).raw")
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: tmp, to: dst)
            return ["ok": true]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    private static func launchMainApp() {
        // Already running (even as a menu bar app with no window)? Then do not start another copy.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.bunduuk.doddy")
        if running.contains(where: { !$0.isTerminated && $0.activationPolicy != .prohibited }) { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-b", "io.github.bunduuk.doddy"]
        try? p.run()
        p.waitUntilExit()
    }

    private static func reply(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var len = UInt32(data.count).littleEndian
        // try?: if Chrome has already closed the pipe, quietly stop instead of crashing
        try? FileHandle.standardOutput.write(contentsOf: Data(bytes: &len, count: 4))
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

enum Notifier {
    private static let delegate = NotifierDelegate()

    static func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        let show = UNNotificationAction(identifier: "reveal", title: "Show in Finder", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "finished", actions: [open, show], intentIdentifiers: [], options: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String, file: URL? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if let file {
            c.categoryIdentifier = "finished"
            c.userInfo = ["path": file.path]
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

final class NotifierDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Show banners even while Doddy is the front app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Clicking the banner opens the file; the buttons choose between opening and showing it in Finder.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async {
                if response.actionIdentifier == "reveal" {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        completionHandler()
    }
}
