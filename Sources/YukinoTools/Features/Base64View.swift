import SwiftUI
import YukinoCore

@MainActor final class Base64ViewModel: ObservableObject {
    @Published var input = "Hello, Yukino!"
    @Published var output = ""
    @Published var status = "UTF-8 text conversion."
    @Published var hasError = false
    func convert(decode: Bool) {
        do {
            output = decode ? try Base64Service.decode(input) : Base64Service.encode(input)
            status = decode ? "Decoded successfully" : "Encoded successfully"
            hasError = false
        } catch { output = ""; hasError = true; status = error.localizedDescription }
    }
}

struct Base64View: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = Base64ViewModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: Tool.base64.title, subtitle: Tool.base64.subtitle)
            HStack(spacing: 10) {
                Button("Encode") { model.convert(decode: false) }.buttonStyle(.borderedProminent)
                Button("Decode") { model.convert(decode: true) }
                Button("Swap") { let value = model.output; model.output = model.input; model.input = value }.disabled(model.output.isEmpty)
                Spacer()
                Button { state.copy(model.output) } label: { Label("Copy output", systemImage: "doc.on.doc") }.disabled(model.output.isEmpty)
                Button("Clear") { model.input = ""; model.output = ""; model.status = "UTF-8 text conversion."; model.hasError = false }
            }.controlSize(.large)
            HSplitView {
                EditorPanel(title: "INPUT", text: $model.input).frame(minWidth: 260)
                EditorPanel(title: "OUTPUT", text: $model.output, editable: false).frame(minWidth: 260)
            }.frame(minHeight: 330)
            InlineMessage(message: model.status, error: model.hasError)
        }.padding(32).background(Color.canvas)
    }
}
