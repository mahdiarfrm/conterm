import Foundation

/// Tiny arithmetic evaluator behind the palette's live calculator.
/// Supports + − * / % ^ (right-associative), parentheses, unary
/// minus, and the × ÷ glyphs. Hand-rolled rather than NSExpression:
/// NSExpression raises ObjC exceptions on malformed input, which
/// would crash on every half-typed keystroke.
enum QuickMath {
    /// One entry point for the palette: plain arithmetic, base
    /// conversion ("0x1f", "255 in hex", "0b101+2"), or unit
    /// conversion ("16gb in mb", "2h in min"). `display` is what the
    /// result row shows after the "="; `insert` is the bare text
    /// Enter types into the terminal.
    static func answer(_ s: String) -> (display: String, insert: String)? {
        let q = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }

        // "<expr> in hex|bin|oct|dec" — evaluate, then re-base.
        if let r = q.range(of: " in ", options: .backwards) {
            let lhs = String(q[..<r.lowerBound])
            let unit = String(q[r.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if let radix = baseNames[unit] {
                guard let v = evaluate(lhs) ?? literal(lhs),
                      v.rounded() == v, abs(v) < 9e15 else { return nil }
                let out = formatRadix(Int64(v), radix: radix)
                return (out, out)
            }
            if let converted = convertUnits(lhs, to: unit) {
                return converted
            }
            return nil
        }

        // A lone base literal converts to decimal.
        if q.hasPrefix("0x") || q.hasPrefix("0b") || q.hasPrefix("0o"),
           let v = literal(q) {
            let out = format(v)
            return (out, out)
        }

        guard let v = evaluate(q) else { return nil }
        let out = format(v)
        return (out, out)
    }

    /// nil when `s` isn't a complete arithmetic expression. Strings
    /// without both a digit and an operator are rejected up front so
    /// ordinary searches ("3024 Day", "ssh-prod") aren't hijacked.
    /// Numbers may be decimal or 0x/0b/0o literals.
    static func evaluate(_ s: String) -> Double? {
        let expr = s.replacingOccurrences(of: "×", with: "*")
                    .replacingOccurrences(of: "÷", with: "/")
                    .replacingOccurrences(of: ",", with: "")
                    .lowercased()
        // Letters beyond the radix alphabet bail early; stray hex-ish
        // words ("ab-cd") pass the gate but fail the number parse.
        let allowed = Set("0123456789abcdefxo.+-*/%^() ")
        guard expr.contains(where: \.isNumber),
              expr.contains(where: { "+-*/%^".contains($0) }),
              !expr.isEmpty,
              expr.allSatisfy({ allowed.contains($0) }) else { return nil }
        var parser = Parser(Array(expr.filter { $0 != " " }))
        guard let v = parser.parseExpression(), parser.atEnd,
              v.isFinite else { return nil }
        return v
    }

    /// A single number on its own — decimal or base literal — with
    /// no operators (which `evaluate` requires).
    private static func literal(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        var parser = Parser(Array(t))
        guard let v = parser.parsePrimary(), parser.atEnd else { return nil }
        return v
    }

    private static let baseNames: [String: Int] = [
        "hex": 16, "bin": 2, "binary": 2, "oct": 8, "dec": 10,
    ]

    private static func formatRadix(_ v: Int64, radix: Int) -> String {
        let sign = v < 0 ? "-" : ""
        let mag = String(v.magnitude, radix: radix)
        switch radix {
        case 16: return "\(sign)0x\(mag)"
        case 2:  return "\(sign)0b\(mag)"
        case 8:  return "\(sign)0o\(mag)"
        default: return "\(sign)\(mag)"
        }
    }

    // MARK: - Unit conversion

    /// Power-of-1024 data sizes (the terminal convention) and wall
    /// time, each normalized to a base unit.
    private static let dataUnits: [String: Double] = [
        "b": 1, "byte": 1, "bytes": 1,
        "kb": 1024, "mb": 1048576, "gb": 1073741824,
        "tb": 1099511627776,
    ]
    private static let timeUnits: [String: Double] = [
        "ms": 0.001, "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1,
        "min": 60, "mins": 60, "minute": 60, "minutes": 60,
        "h": 3600, "hr": 3600, "hour": 3600, "hours": 3600,
        "d": 86400, "day": 86400, "days": 86400,
    ]

    /// "16gb" → mb, "2 h" → min, … Both units must come from the
    /// same table.
    private static func convertUnits(_ lhs: String,
                                     to target: String) -> (String, String)? {
        let t = lhs.trimmingCharacters(in: .whitespaces)
        let numPart = String(t.prefix { $0.isNumber || $0 == "." })
        let unitPart = String(t.dropFirst(numPart.count))
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(numPart), !unitPart.isEmpty else { return nil }
        for table in [dataUnits, timeUnits] {
            if let from = table[unitPart], let to = table[target] {
                let out = format(value * from / to)
                return ("\(out) \(target)", out)
            }
        }
        return nil
    }

    /// Plain decimal output: integers without a fraction, everything
    /// else at up to 10 significant digits.
    static func format(_ v: Double) -> String {
        if v.rounded() == v, abs(v) < 1e15 {
            return String(format: "%.0f", v)
        }
        return String(format: "%.10g", v)
    }

    private struct Parser {
        let chars: [Character]
        var pos = 0
        init(_ chars: [Character]) { self.chars = chars }
        var atEnd: Bool { pos >= chars.count }
        func peek() -> Character? { pos < chars.count ? chars[pos] : nil }

        mutating func parseExpression() -> Double? {
            guard var lhs = parseTerm() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                pos += 1
                guard let rhs = parseTerm() else { return nil }
                lhs = (c == "+") ? lhs + rhs : lhs - rhs
            }
            return lhs
        }

        mutating func parseTerm() -> Double? {
            guard var lhs = parsePower() else { return nil }
            while let c = peek(), c == "*" || c == "/" || c == "%" {
                pos += 1
                guard let rhs = parsePower() else { return nil }
                switch c {
                case "*": lhs *= rhs
                case "/": lhs /= rhs
                default:  lhs = lhs.truncatingRemainder(dividingBy: rhs)
                }
            }
            return lhs
        }

        mutating func parsePower() -> Double? {
            guard let base = parseUnary() else { return nil }
            if peek() == "^" {
                pos += 1
                guard let exp = parsePower() else { return nil }
                return pow(base, exp)
            }
            return base
        }

        mutating func parseUnary() -> Double? {
            if peek() == "-" { pos += 1; return parseUnary().map { -$0 } }
            if peek() == "+" { pos += 1; return parseUnary() }
            return parsePrimary()
        }

        mutating func parsePrimary() -> Double? {
            if peek() == "(" {
                pos += 1
                guard let v = parseExpression(), peek() == ")" else { return nil }
                pos += 1
                return v
            }
            // 0x / 0b / 0o radix literals.
            if peek() == "0", pos + 1 < chars.count,
               let radix = ["x": 16, "b": 2, "o": 8][String(chars[pos + 1])] {
                let digits = Set("0123456789abcdef".prefix(radix))
                let start = pos + 2
                var end = start
                while end < chars.count, digits.contains(chars[end]) { end += 1 }
                guard end > start,
                      let v = UInt64(String(chars[start..<end]), radix: radix)
                else { return nil }
                pos = end
                return Double(v)
            }
            let start = pos
            while let c = peek(), c.isNumber || c == "." { pos += 1 }
            guard pos > start else { return nil }
            return Double(String(chars[start..<pos]))
        }
    }
}
