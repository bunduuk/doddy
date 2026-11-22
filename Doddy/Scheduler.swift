import Foundation
import AppKit

/// Global download speed cap (Setup > Speed limit). 0 = unlimited.
final class SpeedLimiter: @unchecked Sendable {
    static let shared = SpeedLimiter()
    private let lock = NSLock()
    private var nextTime = Date()

    var limitKB: Int { UserDefaults.standard.integer(forKey: "speedLimitKB") }

    /// How long the caller should wait after receiving `n` bytes to stay under the cap.
    func delay(forBytes n: Int) -> TimeInterval {
        let kb = limitKB
        guard kb > 0, n > 0 else { return 0 }
        let bps = Double(kb) * 1024
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if nextTime < now { nextTime = now }
        nextTime = nextTime.addingTimeInterval(Double(n) / bps)
        return min(3, max(0, nextTime.timeIntervalSince(now)))
    }
}

extension DownloadManager {
    var scheduleEnabled: Bool { UserDefaults.standard.bool(forKey: "scheduleEnabled") }
    var scheduleMinutes: Int { UserDefaults.standard.object(forKey: "scheduleMinutes") as? Int ?? 120 }

    /// True while the scheduler is holding new downloads back until the set time.
    var isHeld: Bool {
        guard scheduleEnabled, let h = holdUntil else { return false }
        return h > Date()
    }

    private func nextOccurrence(_ minutes: Int) -> Date? {
        Calendar.current.nextDate(after: Date(),
                                  matching: DateComponents(hour: minutes / 60, minute: minutes % 60),
                                  matchingPolicy: .nextTime)
    }

    /// Called twice a second: releases the queue at the scheduled time and runs the
    /// "when downloads finish" action.
    func tickSchedule() {
        let busy = items.contains { $0.state == .running || $0.waiting }
        if busy {
            wasBusy = true
        } else if wasBusy {
            wasBusy = false
            runAfterQueueAction()
        }

        guard scheduleEnabled else {
            if holdUntil != nil { holdUntil = nil; holdMinutes = -1; pump() }
            return
        }
        let mins = scheduleMinutes
        guard let until = holdUntil else {
            // Engage the hold again once the queue is idle (so a running batch is never frozen).
            if !busy { holdUntil = nextOccurrence(mins); holdMinutes = mins }
            return
        }
        if mins != holdMinutes {
            holdUntil = nextOccurrence(mins)
            holdMinutes = mins
            return
        }
        if Date() >= until {
            holdUntil = nil
            pump()
        }
    }

    private func runAfterQueueAction() {
        let action = UserDefaults.standard.string(forKey: "afterQueue") ?? "none"
        guard action != "none", items.contains(where: { $0.state == .done }) else { return }
        Notifier.post("All downloads finished",
                      action == "quit" ? "Doddy will quit in 15 seconds." : "Your Mac will go to sleep in 15 seconds.")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            // New work arrived in the meantime: do nothing.
            if self.items.contains(where: { $0.state == .running || $0.waiting }) { return }
            if action == "quit" {
                NSApp.terminate(nil)
            } else {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                p.arguments = ["sleepnow"]
                try? p.run()
            }
        }
    }
}
