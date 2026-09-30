import SwiftUI
import AppKit
import YukinoCore

struct DockerCommandsView: View {
    @EnvironmentObject private var state: AppState
    let mirror: Bool
    @AppStorage("dockerMirrorRegistry") private var mirrorRegistry = "dkcf.haoges.cn"
    @AppStorage("dockerTransferRegistry") private var transferRegistry = ""
    @AppStorage("dockerUseSudo") private var sudo = false
    @State private var image = "nginx:1.25"
    @State private var direction = DockerWorkflow.pushToRegistry
    @State private var platform = DockerPlatform.amd64
    @State private var cleanup = false
    @State private var plan: DockerCommandPlan?
    @State private var script = ""
    @State private var message = "Enter an image and registry to build your command plan."
    @State private var hasError = false
    private var tool: Tool { mirror ? .dockerMirror : .dockerTransfer }
    private var registry: Binding<String> { mirror ? $mirrorRegistry : $transferRegistry }
    init(mirror: Bool) {
        self.mirror = mirror
        _platform = State(initialValue: mirror ? .automatic : .amd64)
    }

    var body: some View {
        ToolPage(tool: tool) {
            Panel {
                VStack(alignment: .leading, spacing: 18) {
                    if !mirror {
                        Picker("Direction", selection: $direction) {
                            Text("Local → Registry").tag(DockerWorkflow.pushToRegistry)
                            Text("Registry → Local").tag(DockerWorkflow.pullFromRegistry)
                        }.pickerStyle(.segmented)
                    }
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Image").font(.system(size: 12, weight: .medium))
                            TextField("nginx:1.25", text: $image).textFieldStyle(.roundedBorder)
                            Text(mirror ? "Docker Hub image, with optional namespace." : "Original image name. Its namespace and tag are preserved.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(mirror ? "Mirror registry" : "Private registry / namespace").font(.system(size: 12, weight: .medium))
                            TextField(mirror ? "mirror.example.com" : "registry.example.com:5000/library", text: registry).textFieldStyle(.roundedBorder)
                            Text("Host[:port] with optional path · no https:// prefix")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 24) {
                        Picker("Platform", selection: $platform) {
                            ForEach(DockerPlatform.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.frame(width: 235)
                        Toggle("Use sudo", isOn: $sudo)
                        Toggle("Remove temporary registry tag", isOn: $cleanup)
                        Spacer(minLength: 0)
                    }.font(.system(size: 11))
                    HStack(spacing: 12) {
                        Button("Generate commands") { generate() }.buttonStyle(.borderedProminent)
                        Button("Copy script") { state.copy(script) }.disabled(plan == nil)
                        Button("Export .sh…") { export() }.disabled(plan == nil)
                        Spacer()
                        Label("Command generator", systemImage: "text.badge.checkmark").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            if let plan {
                Panel {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Operation preview").font(.system(size: 16, weight: .semibold))
                        LabeledContent("Source") { Text(plan.source).textSelection(.enabled) }
                        LabeledContent("Destination") { Text(plan.destination).textSelection(.enabled) }
                        Divider()
                        ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                            HStack(alignment: .top, spacing: 14) {
                                Text("\(index + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 16)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(step.title).font(.system(size: 12, weight: .medium))
                                    Text(step.command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Button { state.copy(step.command) } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.plain).help("Copy this command")
                            }
                        }
                    }.font(.system(size: 12))
                }
            }
            EditorPanel(title: "SHELL SCRIPT", text: $script, editable: false).frame(height: 180)
            InlineMessage(message: message, error: hasError)
            Text("Generate and copy commands, then run them in your terminal. Private registries use your existing Docker login. Optional cleanup removes only the registry tag, after the preceding steps succeed.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onAppear { if !registry.wrappedValue.isEmpty { generate() } }
        .onChange(of: image) { _, _ in invalidate() }
        .onChange(of: mirrorRegistry) { _, _ in invalidate() }
        .onChange(of: transferRegistry) { _, _ in invalidate() }
        .onChange(of: direction) { _, _ in invalidate() }
        .onChange(of: platform) { _, _ in invalidate() }
        .onChange(of: sudo) { _, _ in invalidate() }
        .onChange(of: cleanup) { _, _ in invalidate() }
    }
    private func invalidate() {
        plan = nil; script = ""; hasError = false
        message = "Options changed · Generate commands to update the preview."
    }
    private func generate() {
        do {
            let value = try DockerCommandService.plan(image: image, registry: registry.wrappedValue,
                workflow: mirror ? .mirror : direction, platform: platform, sudo: sudo, cleanup: cleanup)
            plan = value; script = value.script; hasError = false
            message = "\(value.steps.count) commands ready · Each step runs only if the previous step succeeds."
        } catch { plan = nil; script = ""; hasError = true; message = error.localizedDescription }
    }
    private func export() {
        guard plan != nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = mirror ? "docker-mirror.sh" : "docker-transfer.sh"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(("#!/bin/sh\n# Generated by Yukino Tools\n\n" + script).utf8).write(to: url, options: .atomic)
            state.notify("Script saved")
        } catch { hasError = true; message = error.localizedDescription }
    }
}
