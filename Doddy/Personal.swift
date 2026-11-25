import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Rules for specific sites

struct SiteRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var host = ""
    var audioOnly = false
    var maxHeight = 0          // 0 = best available
    var folder = ""            // empty = the usual folder
    var convert = ""           // "" = the general setting, else none / mp4 / mp3 / m4a
    var cleanNames = ""        // "" = general setting, "on", "off"
    var chromeCookies = ""     // "" = general setting, "on", "off"

    var summary: String {
        var p: [String] = []
        if audioOnly { p.append("audio only") }
        if maxHeight > 0 { p.append("up to \(maxHeight)p") }
        if !folder.isEmpty { p.append("into " + (folder as NSString).lastPathComponent) }
        if !convert.isEmpty { p.append(convert == "none" ? "no conversion" : "convert to \(convert.uppercased())") }
        if cleanNames == "on" { p.append("tidy names") }
        if chromeCookies == "on" { p.append("Chrome login") }
        return p.isEmpty ? "no changes yet" : p.joined(separator: " · ")
    }
}

enum SiteRules {
    static func normalise(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.contains("://"), let h = URL(string: t)?.host { t = h }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        return t
    }

    static var all: [SiteRule] {
        guard let s = UserDefaults.standard.string(forKey: "siteRules"), let d = s.data(using: .utf8),
              let r = try? JSONDecoder().decode([SiteRule].self, from: d) else { return [] }
        return r
    }

    static func save(_ rules: [SiteRule]) {
        guard let d = try? JSONEncoder().encode(rules), let s = String(data: d, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: "siteRules")
    }

    static func match(_ job: Job) -> SiteRule? {
        let h = normalise(URL(string: job.pageUrl ?? job.url)?.host ?? "")
        guard !h.isEmpty else { return nil }
        return all.first { r in
            let rh = normalise(r.host)
            return !rh.isEmpty && (h == rh || h.hasSuffix("." + rh))
        }
    }

    /// Applies the rule for the job's site (if any) and returns it.
    static func apply(to job: inout Job) -> SiteRule? {
        guard let r = match(job) else { return nil }
        if job.kind == "page" {
            if r.audioOnly { job.audioOnly = true }
            if r.maxHeight > 0 && job.formatHeight == nil && job.audioOnly != true { job.formatHeight = r.maxHeight }
        }
        if !r.convert.isEmpty { job.convertAfter = r.convert }
        if !r.cleanNames.isEmpty { job.cleanNames = (r.cleanNames == "on") }
        if !r.chromeCookies.isEmpty { job.chromeCookies = (r.chromeCookies == "on") }
        return r
    }
}

struct SiteRulesView: View {
    @AppStorage("siteRules") private var stored = ""
    @State private var rules: [SiteRule] = []
    @State private var draft: SiteRule?
    @State private var editingNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Downloads from these sites get your choices automatically, without clicking each time.")
                .font(.caption).foregroundStyle(.secondary)
            if rules.isEmpty {
                Text("No rules yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rules) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.host).fontWeight(.medium)
                        Text(r.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") { draft = r; editingNew = false }.glassButton()
                    Button { rules.removeAll { $0.id == r.id }; SiteRules.save(rules) } label: { Image(systemName: "trash") }
                        .glassButton(tint: Theme.red)
                        .help("Remove this rule")
                }
            }
            Button { draft = SiteRule(); editingNew = true } label: { Label("Add a rule…", systemImage: "plus") }.glassButton(prominent: true, tint: Theme.violet)
        }
        .onAppear { rules = SiteRules.all }
        .onChange(of: stored) { _ in rules = SiteRules.all }
        .sheet(item: $draft) { d in
            SiteRuleEditor(rule: d) { saved in
                if let saved {
                    if editingNew { rules.append(saved) }
                    else if let i = rules.firstIndex(where: { $0.id == saved.id }) { rules[i] = saved }
                    SiteRules.save(rules)
                }
                draft = nil
            }
        }
    }
}

private struct SiteRuleEditor: View {
    @State var rule: SiteRule
    let done: (SiteRule?) -> Void

    private func line<C: View>(_ title: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            control()
        }
    }

    private func general(_ sel: Binding<String>, yes: String = "Yes", no: String = "No") -> some View {
        Picker("", selection: sel) {
            Text("As in settings").tag("")
            Text(yes).tag("on")
            Text(no).tag("off")
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).glassCard(radius: 16)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(LinearGradient(colors: [Theme.violet, Theme.blue], startPoint: .topLeading, endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Rule for a site").font(.title3.weight(.bold))
                    Text("Doddy applies these choices to this website automatically.").font(.caption).foregroundStyle(.secondary)
                }
            }

            card {
                Text("Website").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("youtube.com", text: $rule.host).textFieldStyle(.roundedBorder).controlSize(.large)
            }

            card {
                line("Audio only (MP3)") { Toggle("", isOn: $rule.audioOnly).labelsHidden().toggleStyle(.switch).controlSize(.small) }
                Divider()
                line("Video quality") {
                    Picker("", selection: $rule.maxHeight) {
                        Text("Best available").tag(0)
                        Text("Up to 2160p").tag(2160)
                        Text("Up to 1080p").tag(1080)
                        Text("Up to 720p").tag(720)
                        Text("Up to 480p").tag(480)
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize().disabled(rule.audioOnly)
                }
                Divider()
                line("Save into") {
                    Text(rule.folder.isEmpty ? "the usual folder" : rule.folder).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 150, alignment: .trailing)
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { rule.folder = u.path }
                    }
                    .glassButton()
                    if !rule.folder.isEmpty { Button("Reset") { rule.folder = "" }.glassButton(tint: Theme.orange) }
                }
            }

            card {
                line("Convert when finished") {
                    Picker("", selection: $rule.convert) {
                        Text("As in settings").tag("")
                        Text("Do not convert").tag("none")
                        Text("To MP4").tag("mp4")
                        Text("To MP3").tag("mp3")
                        Text("To M4A").tag("m4a")
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                Divider()
                line("Tidy file names") { general($rule.cleanNames) }
                Divider()
                line("Use my Chrome login") { general($rule.chromeCookies) }
                Text("For members-only sites. Doddy reads your Chrome login for this site only. macOS may ask once; choose Allow.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction).glassButton()
                Button("Save rule") {
                    rule.host = SiteRules.normalise(rule.host)
                    done(rule.host.isEmpty ? nil : rule)
                }
                .keyboardShortcut(.defaultAction)
                .glassButton(prominent: true)
                .disabled(SiteRules.normalise(rule.host).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(ColorfulBackdrop(colors: [Theme.violet, Theme.blue]))
    }
}

// MARK: - Settings export / import

enum SettingsBackup {
    static let keys = ["askBeforeDownload", "saveDir", "showProgressWindow", "maxParallel", "speedLimitKB",
                       "scheduleEnabled", "scheduleMinutes", "afterQueue", "nameTemplate", "subtitlesOn",
                       "subtitleLangs", "translateSubs", "cleanNames", "finishSound", "chromeCookies",
                       "updateRepo", "updateAuto", "watchClipboard", "launchAtLogin", "sortFolders", "convertAfter",
                       "convertDeleteOriginal", "siteRules", "autoRetry", "fastYouTube", "rememberAddresses"]

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    static func export() {
        let d = UserDefaults.standard
        var out: [String: Any] = [:]
        for k in keys { if let v = d.object(forKey: k) { out[k] = v } }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Doddy settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        } catch {
            alert("Could not save the settings", error.localizedDescription)
        }
    }

    static func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                alert("Not a Doddy settings file", "The file does not hold settings."); return
            }
            var n = 0
            // Only plain values: a null or a nested object would crash UserDefaults.
            for k in keys {
                guard let v = obj[k], v is String || v is NSNumber else { continue }
                UserDefaults.standard.set(v, forKey: k); n += 1
            }
            alert("Settings imported", "\(n) settings were restored.")
        } catch {
            alert("Could not read the settings", error.localizedDescription)
        }
    }
}
