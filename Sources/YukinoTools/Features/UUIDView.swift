import SwiftUI
import YukinoCore

@MainActor final class UUIDViewModel: ObservableObject {
    @Published var current = UUID().uuidString.lowercased()
    @Published var uppercase = false
    @Published var count = 10
    @Published var batch = ""
    @Published var error: String?
    func generate() { current = (try? UUIDService.generate(count: 1, uppercase: uppercase).first) ?? "" }
    func generateBatch() {
        do {
            batch = try UUIDService.generate(count: count, uppercase: uppercase).joined(separator: "\n")
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func updateCase() {
        current = uppercase ? current.uppercased() : current.lowercased()
        batch = uppercase ? batch.uppercased() : batch.lowercased()
    }
}

struct UUIDView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = UUIDViewModel()
    var body: some View {
        ToolPage(tool: .uuid) {
            Panel {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Text("UUID v4").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Uppercase", isOn: $model.uppercase).toggleStyle(.switch).controlSize(.small)
                    }
                    Text(model.current).font(.system(size: 24, weight: .medium, design: .monospaced)).textSelection(.enabled)
                    HStack(spacing: 10) {
                        Button("Generate new UUID") { model.generate() }.buttonStyle(.borderedProminent)
                        Button { state.copy(model.current) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Spacer()
                        Text("Cryptographically random · RFC 4122").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Batch generate").font(.system(size: 17, weight: .semibold))
                    HStack(spacing: 12) {
                        Text("Quantity").font(.system(size: 12)).foregroundStyle(.secondary)
                        TextField("Quantity", value: $model.count, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 70)
                        Stepper("Quantity", value: $model.count, in: 1...1000).labelsHidden().fixedSize()
                        Button("Generate batch") { model.generateBatch() }
                        Spacer()
                        Button("Copy all") { state.copy(model.batch) }.disabled(model.batch.isEmpty)
                    }
                    EditorPanel(title: "GENERATED UUIDS", text: $model.batch, editable: false).frame(height: 230)
                    Text("One identifier per line. Up to 1,000 at a time.").font(.system(size: 11)).foregroundStyle(.secondary)
                    if let error = model.error { InlineMessage(message: error, error: true) }
                }
            }
        }.onChange(of: model.uppercase) { _, _ in model.updateCase() }
    }
}
