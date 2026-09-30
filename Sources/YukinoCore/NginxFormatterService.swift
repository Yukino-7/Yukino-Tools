import Foundation

/// An independent, token-preserving formatter. Checks structure, not directive validity.
public enum NginxFormatterService {
    private enum Kind { case word, comment, open, close, semicolon, blank }
    private struct Token { let kind: Kind; let text: String; let line: Int }
    public static func format(_ input: String, indentation: Int = 4, crlf: Bool = false) throws -> String {
        guard (1...8).contains(indentation) else { throw ToolError.invalid("Choose 1–8 spaces for indentation.") }
        guard input.utf8.count <= 2_000_000 else { throw ToolError.invalid("Configuration exceeds the 2 MB editor limit.") }
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError.invalid("Enter an Nginx configuration to format.") }
        let tokens = try tokenize(input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var lines: [String] = []
        var depth = 0
        var pending: [String] = []
        var continued = false
        var previousStatementLine: Int?
        var justClosed = false
        func emit(_ value: String, line: Int) {
            lines.append(String(repeating: " ", count: depth * indentation) + value)
            previousStatementLine = line
        }
        for token in tokens {
            switch token.kind {
            case .word:
                pending.append(token.text); justClosed = false
            case .open:
                guard !pending.isEmpty || continued else { throw error("Block has no directive", token.line) }
                emit(pending.joined(separator: " ") + (pending.isEmpty ? "{" : " {"), line: token.line)
                pending.removeAll(); continued = false; depth += 1; justClosed = false
                guard depth <= 128 else { throw error("Configuration nesting exceeds 128 levels", token.line) }
            case .close:
                guard pending.isEmpty && !continued else { throw error("Missing semicolon before closing brace", token.line) }
                guard depth > 0 else { throw error("Unexpected closing brace", token.line) }
                depth -= 1; emit("}", line: token.line); justClosed = true
            case .semicolon:
                if pending.isEmpty && !continued {
                    guard justClosed, !lines.isEmpty else { throw error("Empty directive", token.line) }
                    lines[lines.count - 1] += ";"
                } else {
                    emit(pending.joined(separator: " ") + ";", line: token.line)
                }
                pending.removeAll(); continued = false; justClosed = false
            case .comment:
                if !pending.isEmpty {
                    emit(pending.joined(separator: " ") + " " + token.text, line: token.line)
                    pending.removeAll(); continued = true
                } else if previousStatementLine == token.line, let last = lines.last, !last.isEmpty {
                    lines[lines.count - 1] += " " + token.text
                } else { emit(token.text, line: token.line) }
            case .blank:
                if pending.isEmpty && !continued && !lines.isEmpty && !(lines.count >= 2 && lines.suffix(2).allSatisfy(\.isEmpty)) { lines.append("") }
                previousStatementLine = nil
            }
        }
        guard depth == 0 else { throw ToolError.invalid("Unclosed block: \(depth) closing brace(s) missing.") }
        guard pending.isEmpty && !continued else { throw ToolError.invalid("Missing semicolon at the end of the configuration.") }
        while lines.last == "" { lines.removeLast() }
        let output = lines.joined(separator: "\n") + "\n"
        return crlf ? output.replacingOccurrences(of: "\n", with: "\r\n") : output
    }
    private static func error(_ message: String, _ line: Int) -> ToolError { .invalid("\(message) · line \(line).") }
    private static func tokenize(_ input: String) throws -> [Token] {
        let chars = Array(input)
        var tokens: [Token] = []
        var word = ""
        var wordLine = 1
        var line = 1
        var index = 0
        var quote: Character?
        var quoteLine = 1
        var variable = false
        var lineHasContent = false
        func flush() {
            if !word.isEmpty { tokens.append(Token(kind: .word, text: word, line: wordLine)); word = "" }
        }
        while index < chars.count {
            let c = chars[index]
            if word.isEmpty { wordLine = line }
            if c == "\\" {
                guard index + 1 < chars.count else { throw error("Dangling escape", line) }
                word.append(c); index += 1; word.append(chars[index])
                if chars[index] == "\n" { line += 1 }
                lineHasContent = true; index += 1; continue
            }
            if let current = quote {
                word.append(c)
                if c == current { quote = nil }
                if c == "\n" { line += 1 }
                lineHasContent = true; index += 1; continue
            }
            if c == "\"" || c == "'" {
                quote = c; quoteLine = line; word.append(c); lineHasContent = true
            } else if variable {
                word.append(c)
                if c == "}" { variable = false }
                if c == "\n" { throw error("Unclosed variable reference", line) }
                lineHasContent = true
            } else if c == "$", index + 1 < chars.count, chars[index + 1] == "{" {
                word += "${"; index += 1; variable = true; lineHasContent = true
            } else if c == "#" && word.isEmpty {
                flush(); var comment = ""
                while index < chars.count && chars[index] != "\n" { comment.append(chars[index]); index += 1 }
                tokens.append(Token(kind: .comment, text: comment, line: line)); lineHasContent = true
                continue
            } else if c.isWhitespace {
                flush()
                if c == "\n" {
                    if !lineHasContent { tokens.append(Token(kind: .blank, text: "", line: line)) }
                    line += 1; lineHasContent = false
                }
            } else if c == ";" || c == "{" || c == "}" {
                flush()
                tokens.append(Token(kind: c == ";" ? .semicolon : c == "{" ? .open : .close, text: String(c), line: line))
                lineHasContent = true
            } else { word.append(c); lineHasContent = true }
            index += 1
        }
        if quote != nil { throw error("Unterminated quoted string", quoteLine) }
        if variable { throw error("Unclosed variable reference", line) }
        flush()
        return tokens
    }
}
