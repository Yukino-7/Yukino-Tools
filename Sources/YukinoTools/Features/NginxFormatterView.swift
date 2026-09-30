import SwiftUI
import AppKit
import YukinoCore

@MainActor final class NginxViewModel: ObservableObject {
    @Published var input = "# Example server\nserver{listen 80;server_name example.com;location /{proxy_pass http://127.0.0.1:8080;proxy_set_header Host $host;}}\n"
    @Published var output = ""
    @Published var status = "Ready to format."
    @Published var hasError = false
    @Published var busy = false
    @Published var indentation = 4
    @Published var crlf = false
    @Published var filename: String?
    var encoding = String.Encoding.utf8
    private var revision = 0
    func invalidate() {
        revision += 1; output = ""; hasError = false
        status = "Input or options changed · Format to update."
    }
    func format(checkOnly: Bool = false) {
        guard !busy else { return }
        let text = input, spaces = indentation, endings = crlf, current = revision
        busy = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try NginxFormatterService.format(text, indentation: spaces, crlf: endings)
                }.value
                if current == revision {
                    if !checkOnly { output = result }
                    hasError = false; status = checkOnly ? "Structure checked · Balanced braces, quotes and terminators." : "Formatted · \(spaces)-space indentation · \(endings ? "CRLF" : "LF")"
                }
            } catch {
                if current == revision { output = ""; status = error.localizedDescription; hasError = true }
            }
            busy = false
        }
    }
    func open() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 2_000_000 else { throw ToolError.invalid("Configuration exceeds the 2 MB editor limit.") }
            let data = try Data(contentsOf: url)
            let text: String
            if let value = String(data: data, encoding: .utf8) { text = value; encoding = .utf8 }
            else if let value = String(data: data, encoding: .isoLatin1) { text = value; encoding = .isoLatin1 }
            else { throw ToolError.invalid("Could not read this file as UTF-8 or Latin-1.") }
            input = text; crlf = text.contains("\r\n"); filename = url.lastPathComponent
            invalidate()
            status = "Loaded \(url.lastPathComponent) · \(encoding == .utf8 ? "UTF-8" : "Latin-1") · Format to preview."
        } catch { status = error.localizedDescription; hasError = true }
    }
    func save() {
        guard !output.isEmpty else { return }
        let panel = NSSavePanel()
        let stem = filename.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "nginx"
        panel.nameFieldStringValue = "\(stem).formatted.conf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let data = output.data(using: encoding) else { throw ToolError.invalid("Output cannot be encoded as Latin-1. Copy it into a UTF-8 file instead.") }
            try data.write(to: url, options: .atomic)
            status = "Saved \(url.lastPathComponent) · \(encoding == .utf8 ? "UTF-8" : "Latin-1")"; hasError = false
        } catch { status = error.localizedDescription; hasError = true }
    }
    func clear() { input = ""; filename = nil; encoding = .utf8; invalidate() }
}

struct NginxFormatterView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = NginxViewModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: Tool.nginx.title, subtitle: Tool.nginx.subtitle)
            HStack(spacing: 10) {
                Button("Open .conf…") { model.open() }.disabled(model.busy)
                Button(model.busy ? "Formatting…" : "Format") { model.format() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut("r", modifiers: .command).disabled(model.busy)
                Button("Check structure") { model.format(checkOnly: true) }.disabled(model.busy)
                Spacer()
                Picker("Indent", selection: $model.indentation) {
                    Text("2 spaces").tag(2); Text("4 spaces").tag(4); Text("8 spaces").tag(8)
                }.frame(width: 145)
                Picker("Line endings", selection: $model.crlf) { Text("LF").tag(false); Text("CRLF").tag(true) }
                    .labelsHidden().frame(width: 105).help("Line endings")
            }.controlSize(.large)
            HSplitView {
                EditorPanel(title: "INPUT", text: $model.input).frame(minWidth: 260)
                EditorPanel(title: "FORMATTED", text: $model.output, editable: false).frame(minWidth: 260)
            }.frame(minHeight: 300)
            HStack {
                if let filename = model.filename { Text(filename).font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Button("Copy output") { state.copy(model.output) }.disabled(model.output.isEmpty)
                Button("Save as…") { model.save() }.disabled(model.output.isEmpty)
                Button("Clear") { model.clear() }.disabled(model.busy)
            }
            InlineMessage(message: model.status, error: model.hasError)
            Text("Preserves quoted values, comments, escaped characters and ${variables}. Structure checking covers braces, quotes and terminators; run nginx -t on your deployment host to validate directives and included files.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(32).background(Color.canvas)
            .onAppear { model.format() }
            .onChange(of: model.input) { _, _ in model.invalidate() }
            .onChange(of: model.indentation) { _, _ in model.invalidate() }
            .onChange(of: model.crlf) { _, _ in model.invalidate() }
    }
}
