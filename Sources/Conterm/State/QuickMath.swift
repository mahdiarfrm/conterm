import Foundation

/// Tiny arithmetic evaluator behind the palette's live calculator.
/// Supports + − * / % ^ (right-associative), parentheses, unary
/// minus, and the × ÷ glyphs. Hand-rolled rather than NSExpression:
/// NSExpression raises ObjC exceptions on malformed input, which
/// would crash on every half-typed keystroke.
enum QuickMath {
    /// nil when `s` isn't a complete arithmetic expression. Strings
    /// without both a digit and an operator are rejected up front so
    /// ordinary searches ("3024 Day", "ssh-prod") aren't hijacked.
    static func evaluate(_ s: String) -> Double? {
        let expr = s.replacingOccurrences(of: "×", with: "*")
                    .replacingOccurrences(of: "÷", with: "/")
                    .replacingOccurrences(of: ",", with: "")
        let allowed = Set("0123456789.+-*/%^() ")
        guard expr.contains(where: \.isNumber),
              expr.contains(where: { "+-*/%^".contains($0) }),
              !expr.isEmpty,
              expr.allSatisfy({ allowed.contains($0) }) else { return nil }
        var parser = Parser(Array(expr.filter { $0 != " " }))
        guard let v = parser.parseExpression(), parser.atEnd,
              v.isFinite else { return nil }
        return v
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
            let start = pos
            while let c = peek(), c.isNumber || c == "." { pos += 1 }
            guard pos > start else { return nil }
            return Double(String(chars[start..<pos]))
        }
    }
}
