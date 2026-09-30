import SwiftUI
import YukinoCore

@MainActor final class JSONViewModel: ObservableObject {
    @Published var input = "{\"name\":\"Yukino\",\"tools\":[\"JSON\",\"Timestamp\",\"UUID\"],\"native\":true,\"version\":0.1}"
    @Published var output = ""
    @Published var status = "Ready to format."
    @Published var hasError = false
    func transform(minify: Bool = false) {
        do {
            output = try JSONService.transform(input, minify: minify)
            status = minify ? "Valid JSON · Minified" : "Valid JSON · Formatted"
            hasError = false
        } catch { output = ""; status = error.localizedDescription; hasError = true }
    }
    func validate() {
        do {
            _ = try JSONService.transform(input)
            hasError = false; status = "Valid JSON"
        } catch { hasError = true; status = error.localizedDescription }
    }
    func clear() { input = ""; output = ""; status = "Ready to format."; hasError = false }
}

struct JSONFormatterView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = JSONViewModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: Tool.json.title, subtitle: Tool.json.subtitle)
            HStack(spacing: 10) {
                Button("Format") { model.transform() }.buttonStyle(.borderedProminent).keyboardShortcut("r", modifiers: .command)
                Button("Minify") { model.transform(minify: true) }
                Button("Validate") { model.validate() }
                Spacer()
                Button { state.copy(model.output) } label: { Label("Copy output", systemImage: "doc.on.doc") }.disabled(model.output.isEmpty)
                Button("Clear") { model.clear() }
            }.controlSize(.large)
            HSplitView {
                EditorPanel(title: "INPUT", text: $model.input, json: true).frame(minWidth: 260)
                EditorPanel(title: "OUTPUT", text: $model.output, editable: false, json: true).frame(minWidth: 260)
            }.frame(minHeight: 330)
            InlineMessage(message: model.status, error: model.hasError)
        }.padding(32).background(Color.canvas)
            .onAppear { if model.output.isEmpty { model.transform() } }
            .onChange(of: model.input) { _, _ in
                model.output = ""; model.status = "Input changed · Format or validate to update."; model.hasError = false
            }
    }
}
