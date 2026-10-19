import Foundation

/// How often and how recently the command bar picked something: score = count * 0.5^(days since last / 7).
enum Frecency {
    private static let key = "frecency"   // [item key: [count, last-used timestamp]]

    private static var table: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private static func decayed(_ e: [Double], _ now: Date) -> Double {
        guard e.count == 2 else { return 0 }
        return e[0] * pow(0.5, max(0, now.timeIntervalSince1970 - e[1]) / 86_400 / 7)
    }

    static func score(_ item: String, now: Date = Date()) -> Double { table[item].map { decayed($0, now) } ?? 0 }

    static func record(_ item: String, now: Date = Date()) {
        var t = table
        t[item] = [score(item, now: now) + 1, now.timeIntervalSince1970]   // fold the decay into the count
        table = t.filter { decayed($0.value, now) > 0.05 }                  // forget what has faded away
    }
}
