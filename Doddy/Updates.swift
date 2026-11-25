import Foundation
import AppKit

/// Looks for a newer release on GitHub. Off until a repository such as "name/doddy" is set in the options.
enum UpdateChecker {
    private static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
        let y = b.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private static var timer: Timer?

    /// Checks at start-up and then every few hours while Doddy stays open (it often runs for days in the menu bar).
    static func startAutomaticChecks() {
        checkIfDue()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { _ in checkIfDue() }
    }

    /// At most twice a day, quietly, and only when "Check automatically" is on (it is by default).
    static func checkIfDue() {
        let d = UserDefaults.standard
        guard d.object(forKey: "updateAuto") as? Bool ?? true else { return }
        let last = d.object(forKey: "updateLastCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 12 * 3600 else { return }
        Task { await check(manual: false) }
    }

    static func check(manual: Bool) async {
        let repo = (UserDefaults.standard.string(forKey: "updateRepo") ?? "bunduuk/doddy").trimmingCharacters(in: .whitespaces)
        guard !repo.isEmpty, let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            if manual { await show("Updates are not set up", "Type a GitHub repository such as name/doddy in the options first.", nil) }
            return
        }
        UserDefaults.standard.set(Date(), forKey: "updateLastCheck")
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            if manual { await show("Could not check for updates", "Check the repository name and your connection.", nil) }
            return
        }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        if isNewer(tag, than: current) {
            // An automatic check tells you once per version; "Check now" always tells you.
            let d = UserDefaults.standard
            if manual || d.string(forKey: "updateNotified") != tag {
                d.set(tag, forKey: "updateNotified")
                await show("Doddy \(tag) is available", "You have \(current). Download the .dmg from the release page, drag Doddy into Applications, then reload the extension.", page)
            }
        } else if manual {
            await show("You are up to date", "Doddy \(current) is the latest version.", nil)
        }
    }

    @MainActor
    private static func show(_ title: String, _ text: String, _ page: URL?) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        if page != nil { a.addButton(withTitle: "Open download page") }
        a.addButton(withTitle: page == nil ? "OK" : "Later")
        if a.runModal() == .alertFirstButtonReturn, let page { NSWorkspace.shared.open(page) }
    }
}
