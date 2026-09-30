import Foundation

public enum ToolError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public enum JSONService {
    public static func transform(_ input: String, minify: Bool = false) throws -> String {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalid("Enter JSON to get started.")
        }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(input.utf8), options: [.fragmentsAllowed])
            // Validate with Foundation; transform original tokens to preserve large numbers,
            // decimal spelling, escape sequences, duplicate keys, and key ordering.
            let compact = compactTokens(input)
            return minify ? compact : prettyPrint(compact)
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            throw ToolError.invalid("Invalid JSON · \(detail ?? error.localizedDescription)")
        }
    }
    private static func compactTokens(_ input: String) -> String {
        var output = ""
        var inString = false
        var escaped = false
        for character in input {
            if inString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
                output.append(character)
            } else if !character.isWhitespace { output.append(character) }
        }
        return output
    }
    private static func prettyPrint(_ compact: String) -> String {
        let characters = Array(compact)
        var output = ""
        var depth = 0
        var inString = false
        var escaped = false
        func newline() { output += "\n" + String(repeating: "  ", count: max(0, depth)) }
        for (index, character) in characters.enumerated() {
            if inString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true; output.append(character)
            case "{", "[":
                output.append(character)
                let close: Character = character == "{" ? "}" : "]"
                if index + 1 < characters.count && characters[index + 1] != close {
                    depth += 1
                    newline()
                }
            case "}", "]":
                let open: Character = character == "}" ? "{" : "["
                if index > 0 && characters[index - 1] != open { depth -= 1; newline() }
                output.append(character)
            case ",": output.append(character); newline()
            case ":": output += ": "
            default: output.append(character)
            }
        }
        return output
    }

}

public enum Base64Service {
    public static func encode(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
    public static func decode(_ text: String) throws -> String {
        let cleaned = text.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: cleaned), let value = String(data: data, encoding: .utf8) else {
            throw ToolError.invalid("Invalid Base64 or non-UTF-8 content. This converter supports UTF-8 text.")
        }
        return value
    }
}

public enum TimestampService {
    public enum Unit: String, CaseIterable, Sendable { case seconds = "Seconds", milliseconds = "Milliseconds" }
    public static func date(from input: String, unit: Unit) throws -> Date {
        guard let value = Double(input.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
            throw ToolError.invalid("Enter a valid numeric timestamp.")
        }
        let seconds = unit == .milliseconds ? value / 1000 : value
        guard seconds >= -62135596800, seconds <= 253402300799 else {
            throw ToolError.invalid("Timestamp must fall between years 0001 and 9999.")
        }
        return Date(timeIntervalSince1970: seconds)
    }
    public static func timestamp(from date: Date, unit: Unit) -> String {
        String(Int64((date.timeIntervalSince1970 * (unit == .milliseconds ? 1000 : 1)).rounded(.down)))
    }
    public static func formatter(utc: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = utc ? TimeZone(secondsFromGMT: 0) : .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        return formatter
    }
    public static func parse(_ input: String, utc: Bool) throws -> Date {
        let formatter = formatter(utc: utc)
        guard let date = formatter.date(from: input), formatter.string(from: date) == input else {
            throw ToolError.invalid("Use yyyy-MM-dd HH:mm:ss, with a valid calendar date.")
        }
        return date
    }
}

public enum UUIDService {
    public static func generate(count: Int, uppercase: Bool = false) throws -> [String] {
        guard (1...1000).contains(count) else { throw ToolError.invalid("Choose between 1 and 1,000 UUIDs.") }
        return (0..<count).map { _ in
            let value = UUID().uuidString
            return uppercase ? value : value.lowercased()
        }
    }
}
