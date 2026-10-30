import Foundation

/// Transport detection is independent of the AI event extraction mode.
public enum HTTPResponseService {
    public static func contentType(_ headers: String) -> String? {
        let lines = headers.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let start = lines.lastIndex(where: { $0.hasPrefix("HTTP/") }) else { return nil }
        return lines.dropFirst(start + 1).first(where: { $0.lowercased().hasPrefix("content-type:") })?
            .split(separator: ":", maxSplits: 1).last?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func isEventStream(headers: String, prefix: Data, forced: Bool = false) -> Bool {
        if forced { return true }
        if let type = contentType(headers) { return type == "text/event-stream" }
        var text = String(decoding: prefix.prefix(4096), as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["data:", "event:", ":", "id:", "retry:"].contains(where: text.hasPrefix)
    }

    /// Formats original JSON tokens rather than reserializing numbers or object keys.
    public static func formattedJSON(_ data: Data) -> String? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return try? JSONService.transform(text)
    }
}
