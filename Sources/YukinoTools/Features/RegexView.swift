import SwiftUI
import YukinoCore

@MainActor final class RegexViewModel: ObservableObject {
    @Published var pattern = #"([A-Z]+)-(\d+)"#
    @Published var text = "YUKINO-2026\nTOOLS-42\nhello world"
    @Published var replacement = "$1 #$2"
    @Published var options = RegexOptions()
    @Published var result: RegexResult?
    @Published var error: String?
    @Published var working = false
    private var operation: Task<Void, Never>?
    func refresh() {
        operation?.cancel(); result = nil; error = nil
        guard !pattern.isEmpty else { working = false; return }
        working = true
        let pattern = pattern, text = text, replacement = replacement, options = options
        operation = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let worker = Task.detached(priority: .userInitiated) {
                    try RegexService.evaluate(pattern: pattern, text: text, replacement: replacement, options: options)
                }
                let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                result = value; working = false
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription; working = false
            }
        }
    }
    func cancel() { operation?.cancel(); working = false }
}

struct RegexView: View {
    @StateObject private var model = RegexViewModel()
    @EnvironmentObject private var state: AppState
    var body: some View {
        ToolPage(tool: .regex) {
            Panel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        TextField("输入表达式，无需 / 分隔符", text: $model.pattern)
                            .font(.system(size: 14, design: .monospaced)).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("正则表达式")
                        Menu("示例") {
                            Button("编号与捕获组") { example(#"([A-Z]+)-(\d+)"#, "YUKINO-2026\nTOOLS-42", "$1 #$2") }
                            Button("提取日期") { example(#"(\d{4})-(\d{2})-(\d{2})"#, "日期：2026-10-21、2026-12-31", "$1/$2/$3") }
                            Button("多行开头") { example(#"^\w+"#, "first line\nsecond line", "[$0]"); model.options.multiline = true }
                            Button("中文与 Unicode") { example(#"\p{Han}+"#, "Hello 雪乃，工具箱 ready!", "[$0]") }
                        }.fixedSize()
                        Button("清空") { model.pattern = ""; model.text = ""; model.replacement = "" }
                    }
                    HStack(spacing: 22) {
                        Toggle("i · 忽略大小写", isOn: $model.options.ignoreCase)
                        Toggle("m · 多行锚点", isOn: $model.options.multiline)
                        Toggle("s · 点匹配换行", isOn: $model.options.dotMatchesNewline)
                    }.toggleStyle(.checkbox).font(.system(size: 12))
                    Text("ICU / NSRegularExpression 语法，默认全局匹配。与 JavaScript、Python 的语法可能不同。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            EditorPanel(title: "测试文本 · 匹配高亮", text: $model.text, matchRanges: model.result?.matches.map(\.range) ?? []).frame(height: 230)
            if model.working { ProgressView("正在匹配…") }
            if let error = model.error { InlineMessage(message: error, error: true) }
            if let result = model.result {
                Panel {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("\(result.truncated ? "至少 " : "")\(result.matches.count) 处匹配").font(.headline)
                            Spacer()
                            Button("复制匹配") { state.copy(result.matches.map(\.text).joined(separator: "\n")) }.disabled(result.matches.isEmpty)
                        }
                        if result.truncated { InlineMessage(message: "仅保留前 1,000 处匹配；替换预览已停用，请缩小匹配范围。", error: true) }
                        if result.matches.isEmpty { Text("没有匹配到内容。").font(.system(size: 12)).foregroundStyle(.secondary) }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(result.matches) { match in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("#\(match.index) · UTF-16 位置 \(match.range.location)，长度 \(match.range.length)\(match.range.length == 0 ? "（零宽匹配）" : "")")
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                        Text(match.text.isEmpty ? "∅" : match.text).font(.system(size: 12, design: .monospaced)).lineLimit(4).textSelection(.enabled)
                                        ForEach(match.captures) { capture in
                                            HStack(alignment: .top, spacing: 10) {
                                                Text("$\(capture.index)").foregroundStyle(.secondary)
                                                Text(capture.text.map { $0.isEmpty ? "（空字符串）" : $0 } ?? "（未参与匹配）").lineLimit(3)
                                            }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                        }
                                        Divider()
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }.frame(maxHeight: 300)
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("替换预览").font(.headline)
                    TextField("替换模板，例如 $1 或 [$0]", text: $model.replacement)
                        .textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
                        .accessibilityLabel("正则替换模板")
                    Text("$0 为整个匹配，$1、$2 为捕获组；反斜杠用于转义。空模板会删除匹配内容。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    EditorPanel(title: "替换结果", text: .constant(model.result?.replacement ?? ""), editable: false).frame(height: 160)
                    Button("复制替换结果") { state.copy(model.result?.replacement ?? "") }.disabled(model.result?.replacement == nil)
                }
            }
            Text("所有处理均在本机进行。匹配时间预算 0.5 秒，最多保留 1,000 处匹配；零宽匹配在结果列表显示。输入和替换结果不写入历史。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onAppear { model.refresh() }
        .onChange(of: model.pattern) { _, _ in model.refresh() }
        .onChange(of: model.text) { _, _ in model.refresh() }
        .onChange(of: model.replacement) { _, _ in model.refresh() }
        .onChange(of: model.options) { _, _ in model.refresh() }
        .onDisappear { model.cancel() }
    }
    private func example(_ pattern: String, _ text: String, _ replacement: String) {
        model.options = .init(); model.pattern = pattern; model.text = text; model.replacement = replacement
    }
}
