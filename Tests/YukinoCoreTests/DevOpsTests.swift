import Foundation
import Testing
@testable import YukinoCore

@Test func dockerReferencesDistinguishRegistryPortsFromTagsAndPreserveNamespaces() throws {
    let ref = try DockerImageReference("registry.example.com:5000/team/my-app:v2")
    #expect(ref.registry == "registry.example.com:5000")
    #expect(ref.path == "team/my-app")
    #expect(ref.tag == "v2")
    #expect(try DockerImageReference("registry.example.com:5000/team/my-app").tag == "latest")
    #expect(try DockerImageReference("nginx").value == "nginx:latest")
    #expect(try DockerImageReference("team/app:V2_1").path == "team/app")
}

@Test func dockerRejectsInjectionInvalidPortsAndDigestRetagging() throws {
    for image in ["", "nginx:$(touch /tmp/pwned)", "nginx:latest;echo", "Team/App:v1", "nginx@sha256:abcd", "foo//bar:v1", "--help", "registry.example.com:70000/nginx:v1", "nginx:"] {
        #expect(throws: ToolError.self) { try DockerImageReference(image) }
    }
    for prefix in ["", "registry", "https://registry.example.com", "registry.example.com;echo", "localhost:0/library", "localhost:abc/library", "registry.example.com/BadNamespace"] {
        #expect(throws: ToolError.self) { try DockerCommandService.plan(image: "nginx:v1", registry: prefix, workflow: .pushToRegistry) }
    }
}

@Test func dockerMirrorProducesRestoreWorkflowAndOptionalCleanup() throws {
    let plan = try DockerCommandService.plan(image: "docker.io/team/app:v1", registry: "mirror.example.com/", workflow: .mirror, sudo: true, cleanup: true)
    #expect(plan.source == "mirror.example.com/team/app:v1")
    #expect(plan.destination == "docker.io/team/app:v1")
    #expect(plan.steps.map(\.arguments) == [
        ["pull", "mirror.example.com/team/app:v1"],
        ["tag", "mirror.example.com/team/app:v1", "docker.io/team/app:v1"],
        ["image", "ls", "--filter", "reference=docker.io/team/app:v1"],
        ["rmi", "mirror.example.com/team/app:v1"]
    ])
    #expect(plan.steps.allSatisfy { $0.sudo })
    #expect(throws: ToolError.self) { try DockerCommandService.plan(image: "ghcr.io/team/app:v1", registry: "mirror.example.com", workflow: .mirror) }
}

@Test func dockerTransferMapsBothDirectionsAndKeepsCleanupAfterPush() throws {
    let push = try DockerCommandService.plan(image: "ghcr.io/team/app:v1", registry: "registry.example.com:5000/library", workflow: .pushToRegistry, platform: .amd64, cleanup: true)
    #expect(push.destination == "registry.example.com:5000/library/team/app:v1")
    #expect(push.steps[0].arguments == ["pull", "--platform=linux/amd64", "ghcr.io/team/app:v1"])
    #expect(push.steps[2].arguments == ["push", push.destination])
    #expect(push.steps.last?.arguments == ["rmi", push.destination])
    let pull = try DockerCommandService.plan(image: "team/app:v1", registry: "registry.example.com:5000/library", workflow: .pullFromRegistry, platform: .arm64)
    #expect(pull.source == push.destination)
    #expect(pull.destination == "team/app:v1")
    #expect(!pull.steps.contains { $0.arguments.first == "push" || $0.arguments.first == "rmi" })
    #expect(throws: ToolError.self) { try DockerCommandService.plan(image: "registry.example.com/team/app:v1", registry: "registry.example.com", workflow: .pushToRegistry) }
}

@Test func generatedDockerShellStopsBeforePushAndCleanupWhenRetaggingFails() throws {
    let plan = try DockerCommandService.plan(image: "nginx:v1", registry: "registry.example.com/library", workflow: .pushToRegistry, platform: .amd64, cleanup: true)
    // A shell function records arguments; no Docker executable, registry or daemon is used.
    let script = "docker() { printf '%s\\n' \"$*\"; if [ \"$1\" = tag ]; then return 17; fi; };\n" + plan.script
    let process = Process(); let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]; process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    let output = try #require(String(data: data, encoding: .utf8))
    #expect(process.terminationStatus == 17)
    #expect(output.components(separatedBy: "\n").filter { !$0.isEmpty } == [
        "pull --platform=linux/amd64 nginx:v1", "tag nginx:v1 registry.example.com/library/nginx:v1"
    ])
}

@Test func nginxFormatsNestedBlocksAndIsIdempotent() throws {
    let input = "http{server\n{listen 80;location /{proxy_pass http://localhost:8080;}}}"
    let expected = "http {\n    server {\n        listen 80;\n        location / {\n            proxy_pass http://localhost:8080;\n        }\n    }\n}\n"
    let result = try NginxFormatterService.format(input)
    #expect(result == expected)
    #expect(try NginxFormatterService.format(result) == result)
}

@Test func nginxPreservesQuotesEscapesVariablesAndCommentPlacement() throws {
    let input = #"""
    # header { } ;
    server{listen 80; # keep inline
    set $value "a  b; # not a comment {1,3}";
    set $escaped 'it\'s  ok';
    set $path ${document_root}/assets;
    set $literal foo\;bar;
    set $hash foo#bar;
    rewrite "^/item/[0-9]{1,3}$" /index last;
    proxy_set_header Host # split directive comment
    $host;
    }
    """#
    let result = try NginxFormatterService.format(input, indentation: 2)
    for preserved in [#""a  b; # not a comment {1,3}""#, #"'it\'s  ok'"#, "${document_root}/assets", #"foo\;bar"#, "foo#bar", #""^/item/[0-9]{1,3}$""#] { #expect(result.contains(preserved)) }
    #expect(result.contains("  listen 80; # keep inline\n"))
    #expect(result.contains("proxy_set_header Host # split directive comment\n"))
    #expect(try NginxFormatterService.format(result, indentation: 2) == result)
}

@Test func nginxHandlesCRLFMultilineQuotedValuesAndBlankLineLimits() throws {
    let input = "# comment\r\n\r\n\r\n\r\nserver {\r\nset $x \"first\r\n second;{ }\";\r\n}\r\n"
    let result = try NginxFormatterService.format(input, indentation: 8, crlf: true)
    #expect(result.contains("\r\n        set $x \"first\r\n second;{ }\";\r\n"))
    #expect(!result.contains("\r\n\r\n\r\n\r\n"))
    #expect(try NginxFormatterService.format(result, indentation: 8, crlf: true) == result)
}

@Test func nginxRejectsBrokenStructureWithoutReturningPartialConfiguration() throws {
    for input in ["", "server { listen 80 }", "}", "server { listen 80;", "set $x \"unfinished;", "set $x '${value;", "set $x ${value;", "listen 80", "server { ; }", "listen 80;\\"] {
        #expect(throws: ToolError.self) { try NginxFormatterService.format(input) }
    }
    #expect(throws: ToolError.self) { try NginxFormatterService.format("listen 80;", indentation: 0) }
}
