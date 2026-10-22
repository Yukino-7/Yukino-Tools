import SwiftUI
import AppKit
import YukinoCore

@MainActor final class CurlViewModel: ObservableObject {
    enum Mode: String, CaseIterable { case build = "填写请求", convert = "粘贴并转换" }
    @Published var mode = Mode.build
    @Published var request = CurlRequest()
    @Published var sourceShell = CurlShell.bash
    @Published var targetShell = CurlShell.bash
    @Published var multiline = true
    @Published var cmdStyle = CurlCMDStyle.native
    @Published var checking = false
    @Published var inputCommand = ""
    @Published var command = ""
    @Published var warnings = [String]()
    @Published var error: String?
    @Published var plan: CurlCommandPlan?
    private var importedPlan: CurlCommandPlan?
    private var importOperation: Task<Void, Never>?
    init() {
        request.query = [.init()]; request.headers = [.init()]; request.form = [.init()]
    }
    func refresh() {
        command = ""; warnings = []; error = nil; plan = nil
        do {
            let value: CurlCommandPlan
            if mode == .build { value = try CurlCommandService.plan(request) }
            else { guard let importedPlan else { return }; value = importedPlan }
            let rendered = try CurlShellService.render(value, shell: targetShell, multiline: multiline, cmdStyle: cmdStyle, prettyJSON: true)
            plan = value; command = rendered.text; warnings = value.warnings + rendered.warnings
        } catch { self.error = error.localizedDescription }
    }
    func scheduleImport() {
        cancelImport()
        importedPlan = nil; command = ""; warnings = []; plan = nil; error = nil
        guard mode == .convert, !inputCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let source = inputCommand, shell = sourceShell
        checking = true
        importOperation = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let worker = Task.detached(priority: .userInitiated) {
                    try CurlCommandParser.parse(source, shell: shell)
                }
                let parsed = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                importedPlan = parsed; checking = false; refresh()
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                checking = false; self.error = error.localizedDescription
            }
        }
    }
    func cancelImport() { importOperation?.cancel(); importOperation = nil; checking = false }
    func activate() {
        if mode == .convert { scheduleImport() }
        else { cancelImport(); refresh() }
    }
    func clear() {
        cancelImport()
        request = CurlRequest(); request.url = ""; request.query = [.init()]; request.headers = [.init()]; request.form = [.init()]
        inputCommand = ""; importedPlan = nil; command = ""; warnings = []; error = nil; plan = nil
    }
    func example(_ body: CurlBodyMode) {
        var value = CurlRequest()
        value.query = [.init(name: "page", value: "1")]
        value.headers = [.init(name: "Accept", value: "application/json")]
        value.form = [.init(name: "name", value: "Yukino"), .init(name: "tag", value: "tools")]
        if body != .none {
            value.method = .post; value.bodyMode = body
            value.body = body == .json ? "{\n  \"name\": \"Yukino\",\n  \"enabled\": true\n}" : "Hello, Yukino!"
        }
        request = value
    }
    func export() {
        guard let plan else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "curl-request." + targetShell.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var data = Data()
            if targetShell == .powershell { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) } // Windows PowerShell 5.1 reads UTF-8 with BOM.
            data.append(Data(try CurlShellService.script(plan, shell: targetShell, multiline: multiline, cmdStyle: cmdStyle, prettyJSON: true).utf8))
            try data.write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}

struct CurlView: View {
    @StateObject private var model = CurlViewModel()
    @EnvironmentObject private var state: AppState
    @State private var section = "查询参数"
    @State private var showCredentials = false
    private let sections = ["查询参数", "请求头", "请求体", "认证", "选项"]
    var body: some View {
        ToolPage(tool: .curl) {
            HStack {
                Picker("输入方式", selection: $model.mode) {
                    ForEach(CurlViewModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 260)
                Spacer()
                if model.mode == .build {
                    Menu("载入示例") {
                        Button("GET · 查询参数") { model.example(.none) }
                        Button("POST · JSON") { model.example(.json); section = "请求体" }
                        Button("POST · URL 编码表单") { model.example(.urlEncoded); section = "请求体" }
                        Button("POST · Multipart 文本") { model.example(.multipart); section = "请求体" }
                    }.fixedSize()
                }
                Button("清空") { model.clear() }
            }
            if model.mode == .build { builder } else { importer }
            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Picker("目标终端", selection: $model.targetShell) {
                            ForEach(CurlShell.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.frame(maxWidth: 420)
                        Spacer()
                        Toggle("多行排版", isOn: $model.multiline).toggleStyle(.checkbox)
                    }
                    if model.targetShell == .cmd {
                        HStack {
                            Picker("命令形式", selection: $model.cmdStyle) {
                                ForEach(CurlCMDStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.segmented).frame(maxWidth: 400)
                        }
                        if model.cmdStyle == .powershell {
                            Text("兼容封装会显示编码脚本；要查看 curl.exe 命令，请选择“原生 curl.exe”。").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    if let error = model.error { InlineMessage(message: error, error: true) }
                    if let plan = model.plan {
                        Text(plan.url).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        if model.mode == .convert {
                            Label("语法检查通过 · 已识别 \(plan.arguments.count) 个参数", systemImage: "checkmark.circle")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    EditorPanel(title: "命令预览 · 自动更新", text: .constant(model.command), editable: false)
                        .frame(height: min(420, max(235, CGFloat(model.command.components(separatedBy: "\n").count) * 16 + 76)))
                    HStack {
                        Button { state.copy(model.command) } label: { Label("复制命令", systemImage: "doc.on.doc") }.buttonStyle(.borderedProminent)
                        Button("导出脚本…") { model.export() }
                    }.disabled(model.command.isEmpty)
                    if model.plan?.containsCredentials == true {
                        Text("命令包含认证信息；复制、导出时会保留这些内容。")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    ForEach(model.warnings, id: \.self) { warning in InlineMessage(message: warning, error: true) }
                }
            }
            Text("仅在本机生成和检查命令，不执行请求，不读取导入命令引用的文件。请求内容和凭据不保存到历史或设置。终端转换检查不代表服务端已验证请求。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onAppear { model.activate() }
        .onDisappear { model.cancelImport() }
        .onChange(of: model.request) { _, _ in if model.mode == .build { model.refresh() } }
        .onChange(of: model.mode) { _, _ in model.activate() }
        .onChange(of: model.targetShell) { _, _ in model.refresh() }
        .onChange(of: model.multiline) { _, _ in model.refresh() }
        .onChange(of: model.cmdStyle) { _, _ in model.refresh() }
        .onChange(of: model.inputCommand) { _, _ in model.scheduleImport() }
        .onChange(of: model.sourceShell) { _, _ in model.scheduleImport() }
    }
    private var builder: some View {
        Panel {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Picker("方法", selection: $model.request.method) {
                        ForEach(CurlMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 110).accessibilityLabel("HTTP 请求方法")
                    TextField("https://example.com/api", text: $model.request.url)
                        .textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced)).accessibilityLabel("请求 URL")
                }
                Picker("请求设置", selection: $section) {
                    ForEach(sections, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
                switch section {
                case "查询参数": CurlFieldsEditor(fields: $model.request.query, label: "查询参数")
                case "请求头": CurlFieldsEditor(fields: $model.request.headers, label: "请求头")
                case "请求体": bodyEditor
                case "认证": authentication
                default: options
                }
            }
        }
    }
    private var importer: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker("来源终端", selection: $model.sourceShell) {
                        ForEach(CurlShell.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.frame(maxWidth: 420)
                    Spacer()
                    if model.checking { ProgressView("自动转换中…").controlSize(.small) }
                    else { Label("粘贴后自动转换", systemImage: "bolt.fill").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                EditorPanel(title: "粘贴一条 curl / curl.exe 命令", text: $model.inputCommand).frame(height: 200)
                Text("粘贴或修改命令后自动检查并转换，切换来源或目标终端也会自动更新。多行排版时自动美化命令内的 JSON 请求体，原始输入保留；变量、管道、多请求及未知选项会明确提示。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("类型", selection: $model.request.bodyMode) {
                ForEach(CurlBodyMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.frame(maxWidth: 370)
            switch model.request.bodyMode {
            case .none: Text("此请求不附加请求体。").font(.system(size: 12)).foregroundStyle(.secondary)
            case .json, .text:
                EditorPanel(title: "请求体", text: $model.request.body, json: model.request.bodyMode == .json).frame(height: 185)
                if model.request.bodyMode == .json {
                    Button("美化 JSON") {
                        do { model.request.body = try JSONService.transform(model.request.body) }
                        catch { model.error = error.localizedDescription }
                    }
                }
            case .urlEncoded, .multipart: CurlFieldsEditor(fields: $model.request.form, label: "表单")
            }
        }
    }
    private var authentication: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("认证方式", selection: $model.request.auth) {
                ForEach(CurlAuthMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 440)
            if model.request.auth == .bearer {
                if showCredentials { TextField("Token", text: $model.request.bearerToken).textFieldStyle(.roundedBorder) }
                else { SecureField("Token", text: $model.request.bearerToken).textFieldStyle(.roundedBorder) }
            } else if model.request.auth == .basic {
                TextField("用户名", text: $model.request.username).textFieldStyle(.roundedBorder)
                if showCredentials { TextField("密码", text: $model.request.password).textFieldStyle(.roundedBorder) }
                else { SecureField("密码", text: $model.request.password).textFieldStyle(.roundedBorder) }
            }
            if model.request.auth != .none { Toggle("显示输入的凭据", isOn: $showCredentials).toggleStyle(.checkbox).font(.system(size: 12)) }
        }
    }
    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                Toggle("跟随重定向", isOn: $model.request.followRedirects)
                Toggle("显示响应头", isOn: $model.request.includeHeaders)
                Toggle("详细调试输出", isOn: $model.request.verbose)
            }.toggleStyle(.checkbox).font(.system(size: 12))
            HStack(spacing: 20) {
                Stepper("连接超时：\(model.request.connectTimeout) 秒", value: $model.request.connectTimeout, in: 1...3600)
                Stepper("总超时：\(model.request.timeout) 秒", value: $model.request.timeout, in: 1...3600)
            }.font(.system(size: 12))
        }
    }
}

private struct CurlFieldsEditor: View {
    @Binding var fields: [CurlField]
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(spacing: 9) {
                    ForEach($fields) { $field in
                        HStack(spacing: 10) {
                            Toggle("启用", isOn: $field.enabled).labelsHidden().toggleStyle(.checkbox).accessibilityLabel("启用\(label)")
                            TextField("名称", text: $field.name).textFieldStyle(.roundedBorder).frame(maxWidth: 230).accessibilityLabel("\(label)名称")
                            TextField("值（可为空）", text: $field.value).textFieldStyle(.roundedBorder).accessibilityLabel("\(label)值")
                            Button { fields.removeAll { $0.id == field.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("删除此行")
                        }.font(.system(size: 12)).opacity(field.enabled ? 1 : 0.5)
                    }
                }.padding(.vertical, 2)
            }.frame(height: CGFloat(min(6, max(1, fields.count))) * 32)
            HStack {
                Button { fields.append(.init()) } label: { Label("添加\(label)", systemImage: "plus") }.disabled(fields.count >= 100)
                Text("可勾选启用；完全空白的行忽略，重复名称按原顺序保留。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
