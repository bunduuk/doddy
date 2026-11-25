import Foundation

// Run with tools/test.sh. No test framework: each check prints a line, and any failure ends with exit code 1.
var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ok    " : "  FAIL  ", name)
    if !ok { failures += 1 }
}

print("Completeness")
check(Checks.isComplete(have: 100, expected: 100), "equal size is complete")
check(Checks.isComplete(have: 120, expected: 100), "bigger than announced is complete")
check(!Checks.isComplete(have: 99, expected: 100), "one byte short is incomplete")
check(Checks.isComplete(have: 5, expected: 0), "no announced size cannot be checked, so it passes")

print("Same file on resume")
check(Checks.sameFile(knownETag: "\"a\"", newETag: "\"a\"", knownModified: nil, newModified: nil, knownTotal: 10, newTotal: 10) == .same, "same size and ETag")
check(Checks.sameFile(knownETag: nil, newETag: nil, knownModified: nil, newModified: nil, knownTotal: 10, newTotal: 11) != .same, "size changed")
check(Checks.sameFile(knownETag: "\"a\"", newETag: "\"b\"", knownModified: nil, newModified: nil, knownTotal: 10, newTotal: 10) != .same, "ETag changed, no dates")
check(Checks.sameFile(knownETag: "\"a\"", newETag: "\"b\"", knownModified: "Mon", newModified: "Mon", knownTotal: 10, newTotal: 10) == .same, "ETag differs but same modified date (mirrors)")
check(Checks.sameFile(knownETag: "\"a\"", newETag: "\"b\"", knownModified: "Mon", newModified: "Tue", knownTotal: 10, newTotal: 10) != .same, "ETag and date both changed")
check(Checks.sameFile(knownETag: "W/\"a\"", newETag: "\"a\"", knownModified: nil, newModified: nil, knownTotal: 10, newTotal: 10) == .same, "weak marker ignored")
check(Checks.sameFile(knownETag: nil, newETag: nil, knownModified: "Mon", newModified: "Tue", knownTotal: 10, newTotal: 10) != .same, "no ETag: modified date changed")
check(Checks.sameFile(knownETag: nil, newETag: nil, knownModified: nil, newModified: nil, knownTotal: 10, newTotal: nil) == .same, "nothing to compare passes")
check(Checks.sameFile(knownETag: nil, newETag: nil, knownModified: nil, newModified: nil, knownTotal: 0, newTotal: 10) == .same, "unknown first size passes")

print("Headers")
check(Checks.contentRangeTotal("bytes 0-0/12345") == 12345, "Content-Range total")
check(Checks.contentRangeTotal("bytes 0-0/*") == nil, "unknown total")
check(Checks.contentRangeTotal(nil) == nil, "no header")

print("Disk space")
check(Checks.hasRoom(needed: 1_000, available: 1_000_000_000), "plenty of room")
check(!Checks.hasRoom(needed: 900_000_000, available: 950_000_000), "fits only without the margin")
check(Checks.hasRoom(needed: 900_000_000, available: nil), "unreadable free space does not block")
check(Checks.hasRoom(needed: 0, available: 1), "unknown size does not block")

print("Dynamic splitting")
check(Checks.splitPoint(next: 0, end: 7_999_999) == 4_000_000, "8 MB left is cut in the middle")
check(Checks.splitPoint(next: 0, end: 7_999_998) == nil, "just under 8 MB is not shared")
check(Checks.splitPoint(next: 1_000, end: 20_000_999) == 10_001_000, "cut point is relative to the next byte")
check(Checks.splitPoint(next: 5, end: 3) == nil, "a finished piece cannot be cut")
check(Checks.biggestRemaining([]) == nil, "no pieces")
check(Checks.biggestRemaining([5, 90, 7]) == 1, "the biggest remaining piece")
check(Checks.biggestRemaining([9, 9]) == 0, "first on a tie")
check(Checks.clampWrite(offset: 100, end: 199, count: 50).write == 50 && !Checks.clampWrite(offset: 100, end: 199, count: 50).finished, "chunk well inside the piece")
check(Checks.clampWrite(offset: 100, end: 199, count: 100).write == 100 && Checks.clampWrite(offset: 100, end: 199, count: 100).finished, "chunk ends exactly at the end")
check(Checks.clampWrite(offset: 100, end: 199, count: 300).write == 100 && Checks.clampWrite(offset: 100, end: 199, count: 300).finished, "chunk past the end is trimmed")
check(Checks.clampWrite(offset: 200, end: 199, count: 10).write == 0 && Checks.clampWrite(offset: 200, end: 199, count: 10).finished, "nothing left to write")

// Many cuts in a row must never leave a gap or an overlap: every byte belongs to exactly one piece.
func splitSimulationOK(total: Int64, connections: Int, rounds: Int, seed: UInt64) -> Bool {
    var state = seed
    func rnd(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(n)) }
    var pieces: [[Int64]] = []   // [start, next, end]
    let step = (total + Int64(connections) - 1) / Int64(connections)
    for i in 0..<connections {
        let s = Int64(i) * step, e = min(total - 1, (Int64(i) + 1) * step - 1)
        if s <= e { pieces.append([s, s, e]) }
    }
    for _ in 0..<rounds {
        for i in pieces.indices { pieces[i][1] = min(pieces[i][2] + 1, pieces[i][1] + Int64(rnd(3_000_000))) }   // some progress
        let remaining = pieces.map { max(0, $0[2] - $0[1] + 1) }
        guard let v = Checks.biggestRemaining(remaining),
              let mid = Checks.splitPoint(next: pieces[v][1], end: pieces[v][2]) else { continue }
        let oldEnd = pieces[v][2]
        pieces[v][2] = mid - 1
        pieces.append([mid, mid, oldEnd])
    }
    let sorted = pieces.sorted { $0[0] < $1[0] }
    var expectedStart: Int64 = 0
    for p in sorted {
        if p[0] != expectedStart || p[2] < p[0] || p[1] < p[0] || p[1] > p[2] + 1 { return false }
        expectedStart = p[2] + 1
    }
    return expectedStart == total
}
var simOK = true
for seed in 1...200 { if !splitSimulationOK(total: 1_000_000_000 + Int64(seed) * 12_345, connections: 8, rounds: 60, seed: UInt64(seed)) { simOK = false } }
check(simOK, "200 random runs of repeated cuts leave no gap and no overlap")
check(splitSimulationOK(total: 33_333_333, connections: 3, rounds: 200, seed: 7), "small file, many cuts")

print("Checksums")
check(Checks.hex([0, 15, 255]) == "000fff", "hex")
check(Checks.normalisedHash("  SHA256:ABC DEF\n") == "abcdef", "prefix, spaces and case ignored")
check(Checks.normalisedHash("AbC123") == "abc123", "plain upper case")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
