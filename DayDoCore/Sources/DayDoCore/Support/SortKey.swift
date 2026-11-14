import Foundation

/// Fractional-index sort keys: strings that sort lexicographically and allow
/// inserting between any two neighbours without renumbering other rows. Two
/// devices reordering offline only touch the rows they moved.
public enum SortKey {
    private static let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    private static let base = digits.count

    private static func value(_ c: Character) -> Int { digits.firstIndex(of: c)! }

    /// A key strictly between `a` and `b` (nil = open end).
    public static func between(_ a: String?, _ b: String?) -> String {
        let lo = Array(a ?? "")
        let hi = b.map(Array.init)
        precondition(hi == nil || (a ?? "") < b!, "SortKey.between requires a < b")
        var result: [Character] = []
        var i = 0
        while true {
            let l = i < lo.count ? value(lo[i]) : 0
            let h: Int
            if let hi { h = i < hi.count ? value(hi[i]) : base } else { h = base }
            if h - l > 1 {
                result.append(digits[(l + h) / 2])
                return String(result)
            }
            // Gap too small at this digit: keep lo's digit and go deeper.
            result.append(digits[l])
            if let hi, i < hi.count, h > l {
                // From here on the upper bound is open.
                return String(result) + between(String(lo.dropFirst(i + 1)), nil)
            }
            i += 1
        }
    }

    public static func after(_ a: String?) -> String { between(a, nil) }
    public static func before(_ b: String?) -> String { between(nil, b) }
}
