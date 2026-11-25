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

print("Checksums")
check(Checks.hex([0, 15, 255]) == "000fff", "hex")
check(Checks.normalisedHash("  SHA256:ABC DEF\n") == "abcdef", "prefix, spaces and case ignored")
check(Checks.normalisedHash("AbC123") == "abc123", "plain upper case")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
