import Foundation
import AppKit

/// What is written to history.json for each download, so the list survives quitting the app.
struct SavedItem: Codable {
    var job: Job
    var title: String
    var state: String
    var progress: Double
    var method: String
    var detail: String
    var saveDir: String
    var outputPath: String?
    var waiting: Bool
    var dest: String?
    var total: Int64
    var ranged: Bool
    var segs: [[Int64]]
    var addedAt: Double?          // seconds since 1970 (older history files do not have the next three)
    var finishedAt: Double?
    var expectedBytes: Int64?
    var savedBytes: Int64?
    var hiddenInMenu: Bool?      // cleared from the menu bar list (older history files do not have this)
}

extension DLState {
    var key: String {
        switch self {
        case .pending: return "pending"
        case .queued: return "queued"
        case .running: return "running"
        case .paused: return "paused"
        case .done: return "done"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    init(key: String) {
        switch key {
        case "pending": self = .pending
        case "queued": self = .queued
        case "running": self = .running
        case "paused": self = .paused
        case "done": self = .done
        case "failed": self = .failed
        default: self = .cancelled
        }
    }
}

extension DownloadItem {
    func snapshot() -> SavedItem {
        var j = effectiveJob
        if state == .done || state == .cancelled {
            // Nothing will be requested again, so do not keep the browser cookies around.
            j.cookies = nil
            j.browserHeaders = nil
            j.acceptLanguage = nil
            j.playlistText = nil; j.variantText = nil; j.keyData = nil
            if state == .done && !AddressText.remember { j = j.forgettingAddresses() }
            j.candidates = j.candidates?.map { c in
                var c = c
                c.cookies = nil; c.browserHeaders = nil; c.acceptLanguage = nil
                c.playlistText = nil; c.variantText = nil; c.keyData = nil
                return c
            }
        }
        return SavedItem(job: j, title: title, state: state.key, progress: progress, method: method,
                         detail: detail, saveDir: saveDir.path, outputPath: outputURL?.path,
                         waiting: waiting, dest: resume.dest?.path, total: resume.total,
                         ranged: resume.ranged, segs: resume.segs,
                         addedAt: addedAt.timeIntervalSince1970, finishedAt: finishedAt?.timeIntervalSince1970,
                         expectedBytes: expectedBytes, savedBytes: savedBytes, hiddenInMenu: hiddenInMenu)
    }

    convenience init(saved s: SavedItem) {
        self.init(job: s.job)
        title = s.title
        progress = s.progress
        method = s.method
        detail = s.detail
        saveDir = URL(fileURLWithPath: s.saveDir, isDirectory: true)
        if let p = s.outputPath { outputURL = URL(fileURLWithPath: p) }
        waiting = s.waiting
        hiddenInMenu = s.hiddenInMenu ?? false
        if let t = s.addedAt { addedAt = Date(timeIntervalSince1970: t) }
        if let t = s.finishedAt { finishedAt = Date(timeIntervalSince1970: t) }
        expectedBytes = s.expectedBytes ?? 0
        savedBytes = s.savedBytes ?? 0
        if let d = s.dest {
            resume.dest = URL(fileURLWithPath: d)
            resume.total = s.total
            resume.ranged = s.ranged
            resume.segs = s.segs
        }

        var st = DLState(key: s.state)
        if st == .running || st == .pending {
            // The app was closed (or crashed) mid-download: offer to continue.
            if s.method == "Stream" {
                st = .failed
                detail = "Interrupted when Doddy was closed. Press retry to start again."
            } else {
                st = .paused
                canPause = true
                speed = ""
            }
        } else if st == .paused {
            canPause = true
        }
        state = st
    }
}

extension DownloadManager {
    private static var historyURL: URL { Paths.support.appendingPathComponent("history.json") }

    func saveHistory(force: Bool = false) {
        saveTick += 1
        guard force || saveTick % 4 == 0 else { return }
        let snaps = items.map { $0.snapshot() }
        let previous = lastSavedHistory
        let url = Self.historyURL
        let write = {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            guard let data = try? enc.encode(snaps), data != previous else { return nil as Data? }
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return data
        }
        if force {                       // quitting: finish before the app exits
            if let d = write() { lastSavedHistory = d }
            return
        }
        guard !saving else { return }
        saving = true
        let me = self
        Task.detached(priority: .userInitiated) {
            let d = write()
            await MainActor.run {
                if let d { me.lastSavedHistory = d }
                me.saving = false
            }
        }
    }

    func loadHistory() {
        guard let data = try? Data(contentsOf: Self.historyURL),
              let saved = try? JSONDecoder().decode([SavedItem].self, from: data) else { return }
        items = saved.map { DownloadItem(saved: $0) }
        lastSavedHistory = data
        pump()
    }
}
