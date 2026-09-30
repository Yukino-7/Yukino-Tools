import Foundation

public struct DockerImageReference: Equatable, Sendable {
    public let repository: String
    public let tag: String
    public var value: String { "\(repository):\(tag)" }
    public var path: String {
        let parts = repository.split(separator: "/").map(String.init)
        return Self.hasRegistry(parts) ? parts.dropFirst().joined(separator: "/") : repository
    }
    public var registry: String? {
        let parts = repository.split(separator: "/").map(String.init)
        return Self.hasRegistry(parts) ? parts.first : nil
    }
    public init(_ input: String) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= 383, !input.contains("@"), !input.contains("://") else {
            throw ToolError.invalid("Enter an image name with a tag, such as nginx:1.25. Digest references are not supported by these retagging workflows.")
        }
        let lastPart = input.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if let colon = lastPart.lastIndex(of: ":") {
            tag = String(lastPart[lastPart.index(after: colon)...])
            repository = String(input.dropLast(tag.count + 1))
        } else { repository = input; tag = "latest" }
        guard Self.matches(tag, #"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}"#), repository.count <= 255 else {
            throw ToolError.invalid("Invalid image tag. Use letters, numbers, underscores, dots or hyphens (up to 128 characters).")
        }
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let names: [String]
        if Self.hasRegistry(parts) {
            try Self.validateHost(parts[0])
            names = Array(parts.dropFirst())
        } else { names = parts }
        guard !names.isEmpty, names.allSatisfy(Self.validComponent) else {
            throw ToolError.invalid("Invalid image repository. Use lowercase names, with optional namespace and registry host:port.")
        }
    }
    private static func hasRegistry(_ parts: [String]) -> Bool {
        parts.count > 1 && (parts[0].contains(".") || parts[0].contains(":") || parts[0] == "localhost")
    }
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: "^(?:\(pattern))$", options: .regularExpression) != nil
    }
    static func validComponent(_ value: String) -> Bool {
        matches(value, #"[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*"#)
    }
    static func validateHost(_ host: String) throws {
        let pieces = host.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(pieces.count), !pieces[0].isEmpty,
              pieces[0].split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ matches(String($0), #"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?"#) }),
              pieces.count == 1 || (Int(pieces[1]).map { (1...65535).contains($0) } == true && pieces[1].allSatisfy(\.isNumber)) else {
            throw ToolError.invalid("Invalid registry host or port. Use a host such as registry.example.com:5000, without a URL scheme.")
        }
    }
}

public enum DockerWorkflow: String, CaseIterable, Sendable {
    case mirror, pushToRegistry, pullFromRegistry
}
public enum DockerPlatform: String, CaseIterable, Sendable {
    case automatic = "Automatic", amd64 = "linux/amd64", arm64 = "linux/arm64"
}
public struct DockerCommandStep: Identifiable, Equatable, Sendable {
    public let title: String
    public let arguments: [String]
    public let sudo: Bool
    public var id: String { title }
    public var command: String {
        (sudo ? "sudo " : "") + "docker " + arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }
}
public struct DockerCommandPlan: Equatable, Sendable {
    public let source: String
    public let destination: String
    public let steps: [DockerCommandStep]
    public var script: String { steps.map(\.command).joined(separator: " && \\\n") + "\n" }
}

/// Generates commands only. Never launches Docker or contacts a registry.
public enum DockerCommandService {
    public static func plan(image input: String, registry prefix: String, workflow: DockerWorkflow,
                            platform: DockerPlatform = .automatic, sudo: Bool = false,
                            cleanup: Bool = false) throws -> DockerCommandPlan {
        let image = try DockerImageReference(input)
        let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = prefix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let host = parts.first, !host.isEmpty, host.contains(".") || host.contains(":") || host == "localhost",
              !prefix.contains("://"), prefix.count <= 255, parts.dropFirst().allSatisfy(DockerImageReference.validComponent) else {
            throw ToolError.invalid("Enter a registry host with an optional namespace, such as registry.example.com:5000/library.")
        }
        try DockerImageReference.validateHost(host)
        if workflow == .mirror, let origin = image.registry, origin != "docker.io" && origin != "index.docker.io" {
            throw ToolError.invalid("Docker Mirror expects a Docker Hub image. Use Docker Transfer for other registries.")
        }
        let remote = "\(prefix)/\(image.path):\(image.tag)"
        _ = try DockerImageReference(remote)
        guard remote != image.value else { throw ToolError.invalid("Source and destination are identical. Choose a different registry.") }
        let source = workflow == .pushToRegistry ? image.value : remote
        let destination = workflow == .pushToRegistry ? remote : image.value
        var pull = ["pull"]
        if platform != .automatic { pull += ["--platform=\(platform.rawValue)"] }
        pull.append(source)
        var steps = [DockerCommandStep(title: "Pull image", arguments: pull, sudo: sudo),
                     DockerCommandStep(title: "Retag image", arguments: ["tag", source, destination], sudo: sudo)]
        if workflow == .pushToRegistry {
            steps.append(DockerCommandStep(title: "Push to registry", arguments: ["push", destination], sudo: sudo))
        }
        steps.append(DockerCommandStep(title: "Inspect result", arguments: ["image", "ls", "--filter", "reference=\(destination)"], sudo: sudo))
        if cleanup {
            // Remove the temporary registry tag, never the user's original local tag.
            steps.append(DockerCommandStep(title: "Remove temporary registry tag", arguments: ["rmi", remote], sudo: sudo))
        }
        return DockerCommandPlan(source: source, destination: destination, steps: steps)
    }
}
