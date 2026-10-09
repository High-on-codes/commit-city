/// Locale-free, Foundation-free formatting so output is byte-identical on every machine.
public enum Format {
    /// Days since 1970-01-01 → (year, month, day), proleptic Gregorian (Howard Hinnant's algorithm).
    public static func civil(fromDays days: Int64) -> (year: Int64, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = Int(dayOfYear - (153 * mp + 2) / 5 + 1)
        let month = Int(mp < 10 ? mp + 3 : mp - 9)
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    /// Inverse of `civil(fromDays:)`.
    public static func days(year: Int64, month: Int, day: Int) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let m = Int64(month)
        let dayOfYear = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + Int64(day) - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// "2026-10-09" (UTC).
    public static func date(_ unixSeconds: Int64) -> String {
        let days = unixSeconds >= 0 ? unixSeconds / 86_400 : (unixSeconds - 86_399) / 86_400
        let (year, month, day) = civil(fromDays: days)
        return "\(year)-\(pad2(month))-\(pad2(day))"
    }

    /// Parses "YYYY-MM-DD" (midnight UTC) or a plain Unix timestamp.
    public static func parseTime(_ text: String) -> Int64? {
        if let seconds = Int64(text) { return seconds }
        let parts = text.split(separator: "-")
        guard parts.count == 3, let year = Int64(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        let days = days(year: year, month: month, day: day)
        guard civil(fromDays: days) == (year, month, day) else { return nil }
        return days * 86_400
    }

    static func pad2(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// 12345 → "12,345"
    public static func grouped(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var result = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return value < 0 ? "-" + result : result
    }

    /// One decimal, no trailing ".0", no "-0". Coordinates in SVG never need more.
    public static func coordinate(_ value: Double) -> String {
        decimal(tenths: Format.tenths(value))
    }

    public static func tenths(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((value * 10).rounded())
    }

    /// Integer tenths → shortest decimal: 125 → "12.5", -30 → "-3".
    public static func decimal(tenths: Int) -> String {
        if tenths == 0 { return "0" }
        let sign = tenths < 0 ? "-" : ""
        let magnitude = tenths.magnitude
        let whole = magnitude / 10, fraction = magnitude % 10
        return fraction == 0 ? "\(sign)\(whole)" : "\(sign)\(whole).\(fraction)"
    }

    /// Two decimals for alphas and stroke widths.
    public static func fixed2(_ value: Double) -> String {
        let hundredths = Int((value * 100).rounded())
        let sign = hundredths < 0 ? "-" : ""
        let magnitude = hundredths.magnitude
        let fraction = magnitude % 100
        let whole = magnitude / 100
        if fraction == 0 { return "\(sign)\(whole)" }
        let fractionText = fraction < 10 ? "0\(fraction)" : "\(fraction)"
        let trimmed = fractionText.hasSuffix("0") ? String(fractionText.dropLast()) : fractionText
        return "\(sign)\(whole).\(trimmed)"
    }

    public static func xmlEscaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            // XML 1.0 forbids most control characters even when escaped.
            case "\u{9}", "\u{A}", "\u{D}": result.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20 { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }
}
