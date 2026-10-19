import CoreGraphics

// Prints CGSSessionScreenIsLocked ("1"/"true" when locked, "0" when absent or unlocked).
let dict = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
print(dict["CGSSessionScreenIsLocked"].map { "\($0)" } ?? "0")
