import SwiftUI
import YukinoCore

struct MCPDebuggerView: View {
    @ObservedObject var model: MCPDebuggerModel
    @EnvironmentObject private var state: AppState
    @State private var tab = "参数"
    @State private var resultMode = "正文"
    @State private var advanced = false
    @State private var confirmCall = false
    @State private var logFilter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            connection
            if let error = model.error { InlineMessage(message: error, error: true).lineLimit(3) }
            else if let notice = model.notice { Text(notice).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
            HSplitView {
                catalog.frame(minWidth: 190, idealWidth: 230, maxWidth: 310)
                workspace.frame(minWidth: 380, maxWidth: .infinity)
            }.frame(minHeight: 250)
            Text("连接与凭据仅保留在当前会话。切换工具会断开连接；工具调用由你手动触发，可能修改服务端数据。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(24).background(Color.canvas)
        .sheet(isPresented: $advanced) { advancedSettings }
        .alert("调用 MCP 工具？", isPresented: $confirmCall) {
            Button("取消", role: .cancel) {}
            Button("调用 \(model.selected?.name ?? "工具")") { tab = "结果"; model.perform() }
        } message: {
            Text("服务：\(model.serverName)\n工具：\(model.selected?.name ?? "")\n\n将发送当前 JSON 参数。工具可能写入或删除数据，请确认目标和参数。")
        }
        .onChange(of: model.category) { _, _ in model.changeCategory(); tab = "参数" }
        .onChange(of: model.selectedID) { _, _ in tab = "参数" }
        .onDisappear { model.disconnect() }
    }
    private var header: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: "point.3.connected.trianglepath.dotted", size: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text("MCP 调试器").font(.system(size: 25, weight: .semibold))
                Text("连接服务，检查工具、资源与每一次协议交互。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small); Text(model.action).font(.system(size: 11)).foregroundStyle(.secondary) }
            Button { model.connect(demo: true); tab = "参数" } label: { Label("本地演示", systemImage: "play.circle") }
                .disabled(model.busy || model.connected).help("无需安装服务，不联网、不消耗 Token")
        }
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if model.connected {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text(model.serverName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(model.demo ? "本地演示" : model.configuration.kind.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Text("协议 \(model.version)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                } else {
                    Picker("连接方式", selection: $model.configuration.kind) {
                        ForEach(MCPConnectionKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 195).disabled(model.busy)
                    Spacer()
                    Button("高级设置") { advanced = true }.disabled(model.busy)
                }
                if model.busy { Button("停止等待") { model.stop() } }
                if model.connected || model.busy { Button("断开") { model.disconnect() } }
                else { Button("连接") { model.connect() }.buttonStyle(.borderedProminent) }
            }
            if !model.connected {
                if model.configuration.kind == .stdio {
                    HStack {
                        TextField("可执行文件绝对路径，例如 /opt/homebrew/bin/uvx", text: $model.configuration.executable)
                            .accessibilityLabel("MCP 可执行文件")
                        Button("选择…") { model.chooseExecutable() }
                    }.disabled(model.busy)
                    TextField("参数 JSON 数组，例如 [\"mcp-server-fetch\"]", text: $model.configuration.arguments)
                        .font(.system(size: 11, design: .monospaced)).accessibilityLabel("MCP 启动参数 JSON 数组").disabled(model.busy)
                    Text("直接启动所选程序，不执行 Shell。npx / uvx 可能自行下载包，请检查参数后连接。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    HStack {
                        TextField("https://example.com/mcp", text: $model.configuration.endpoint).accessibilityLabel("MCP HTTP 地址")
                        SecureField("Bearer Token（可选）", text: $model.bearer).frame(maxWidth: 230)
                    }.disabled(model.busy)
                    Text("使用 Streamable HTTP；支持 JSON / SSE POST 响应。OAuth 登录、旧版 HTTP+SSE 与独立 GET 通知流暂不支持。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(14).background(Color.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.hairline, lineWidth: 0.5))
    }
    private var catalog: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("服务目录").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!model.connected || model.busy).help("重新发现当前列表")
            }
            Picker("目录类型", selection: $model.category) {
                ForEach(MCPEntry.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().disabled(model.busy)
            TextField("搜索名称或描述", text: $model.filter).textFieldStyle(.roundedBorder).accessibilityLabel("搜索 MCP 服务目录")
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.visibleEntries) { entry in
                        Button { model.select(entry) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                Text(entry.name).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                if !entry.detail.isEmpty { Text(entry.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(model.selectedID == entry.id ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.busy)
                    }
                    if model.visibleEntries.isEmpty {
                        Text(!model.connected ? "连接服务或点击本地演示。" : !model.supportsCategory ? "服务未声明此项能力。" : model.busy ? "正在发现…" : model.filter.isEmpty ? "服务未提供条目。" : "没有匹配条目。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                }
            }
            Text("\(model.visibleEntries.count) 项").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(14).background(Color.panel, in: RoundedRectangle(cornerRadius: 12))
    }
    private var workspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("详情", selection: $tab) {
                    ForEach(["参数", "结果", "协议日志", "服务信息"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 380)
                Spacer(minLength: 4)
            }
            switch tab {
            case "协议日志": logView
            case "服务信息":
                CodeEditor(text: .constant(model.serverDetails.isEmpty ? "连接后显示服务能力与初始化详情。" : model.serverDetails), editable: false, highlightJSON: true)
            case "结果": resultView
            default:
                if let entry = model.selected { parameterView(entry) }
                else {
                    ContentUnavailableView("检查 MCP 服务", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("从左侧选择工具、资源或 Prompt。\n点击本地演示可以体验完整流程。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.padding(14).background(Color.panel, in: RoundedRectangle(cornerRadius: 12))
    }
    private func parameterView(_ entry: MCPEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title).font(.system(size: 16, weight: .semibold)).textSelection(.enabled)
                    Text(entry.name).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button(entry.kind == .tool ? "调用工具…" : entry.kind == .prompt ? "获取 Prompt" : "读取资源") {
                    guard model.validateOperation() else { return }
                    if entry.kind == .tool { confirmCall = true } else { tab = "结果"; model.perform() }
                }.buttonStyle(.borderedProminent).disabled(!model.connected || model.busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !entry.detail.isEmpty { Text(entry.detail).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
                    if entry.kind == .tool || entry.kind == .prompt {
                        HStack {
                            Text(entry.kind == .tool ? "调用参数 · JSON 对象" : "Prompt 参数 · JSON 字符串对象").font(.system(size: 11, weight: .medium))
                            Spacer()
                            Button("填入示例") { model.arguments = entry.exampleArguments }.controlSize(.small).disabled(model.busy)
                        }
                        CodeEditor(text: $model.arguments, editable: !model.busy, highlightJSON: true).frame(height: 170)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline))
                        Text(entry.kind == .tool ? "示例仅用于起步；请按下方 Schema 检查参数，完整校验由服务端执行。" : "仅获取模板消息，不会发送给模型。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Text(entry.kind == .template ? "将模板参数替换为实际值，再读取完整 URI。" : "资源 URI（由已连接的服务读取）")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("资源 URI", text: $model.resourceURI).textFieldStyle(.roundedBorder).disabled(model.busy)
                    }
                    DisclosureGroup(entry.kind == .tool ? "Input Schema" : "完整定义") {
                        CodeEditor(text: .constant(entry.kind == .tool ? entry.schema : entry.metadata), editable: false, highlightJSON: true).frame(height: 230)
                    }.font(.system(size: 11))
                    if entry.kind == .tool {
                        DisclosureGroup("完整工具定义（含 annotations）") {
                            CodeEditor(text: .constant(entry.metadata), editable: false, highlightJSON: true).frame(height: 230)
                        }.font(.system(size: 11))
                    }
                }
            }
        }
    }
    private var resultView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result = model.result {
                HStack {
                    Label(result.isError ? "工具业务错误" : "返回成功", systemImage: result.isError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(result.isError ? Color.orange : Color.green)
                    Text("\(String(format: "%.0f", result.elapsed * 1000)) ms").foregroundStyle(.secondary)
                    Spacer()
                    Button("复制") { state.copy(resultMode == "正文" && !result.text.isEmpty ? result.text : result.raw) }
                    Button("导出…") { model.exportResult() }
                }.font(.system(size: 11))
                Picker("结果格式", selection: $resultMode) { Text("正文").tag("正文"); Text("完整 JSON").tag("完整 JSON") }
                    .pickerStyle(.segmented).frame(width: 210)
                if resultMode == "正文", result.text.isEmpty {
                    Text("没有文本正文，以下显示完整 JSON。结构化数据与图片、音频的 Base64 均保留在其中。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                CodeEditor(text: .constant(resultMode == "正文" && !result.text.isEmpty ? result.text : result.raw), editable: false,
                           highlightJSON: resultMode != "正文" || result.text.isEmpty)
            } else {
                ContentUnavailableView(model.busy ? "等待返回…" : "暂无调用结果", systemImage: "arrow.down.doc",
                                       description: Text("调用工具、读取资源或获取 Prompt 后，在这里查看结果。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private var logView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("筛选协议日志", text: $logFilter).textFieldStyle(.roundedBorder)
                Button("清空") { model.clearLogs() }
                Button("导出…") { model.exportLogs() }.disabled(model.logs.isEmpty)
            }
            Text("最近 200 条；单条预览最多 16K 字符。日志可能包含敏感参数与服务返回，导出使用同一预览内容。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.logs.filter { logFilter.isEmpty || "\($0.direction) \($0.text)".localizedCaseInsensitiveContains(logFilter) }) { entry in
                        DisclosureGroup {
                            Text(entry.text).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                        } label: {
                            HStack(spacing: 8) {
                                Text(entry.date, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                                Text(entry.direction).fontWeight(.medium)
                                Text(entry.text.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).foregroundStyle(.secondary)
                            }.font(.system(size: 10, design: .monospaced))
                        }.padding(9).background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MCP 连接设置").font(.system(size: 20, weight: .semibold))
            HStack {
                Text("单次请求超时")
                Picker("超时", selection: $model.configuration.timeout) {
                    ForEach([10.0, 30, 60, 120, 300], id: \.self) { Text("\(Int($0)) 秒").tag($0) }
                }.labelsHidden().frame(width: 130)
            }
            if model.configuration.kind == .stdio {
                TextField("工作目录（可选，绝对路径）", text: $model.configuration.directory).textFieldStyle(.roundedBorder)
                Text("附加环境变量 · JSON 字符串对象").font(.system(size: 12, weight: .medium))
                CodeEditor(text: $model.configuration.environment, highlightJSON: true).frame(height: 170)
                Text("在继承的环境上覆盖指定变量；不会执行 Shell 配置文件。")
            } else {
                Text("自定义请求头 · JSON 字符串对象").font(.system(size: 12, weight: .medium))
                CodeEditor(text: $model.configuration.headers, highlightJSON: true).frame(height: 170)
                Text("例如 {\"X-API-Key\": \"…\"}。协议头由程序管理；不自动跟随重定向。")
            }
            Text("仅保留在本次 App 会话，不写入历史、设置或 Keychain。")
            HStack { Spacer(); Button("完成") { advanced = false }.keyboardShortcut(.defaultAction) }
        }.font(.system(size: 11)).padding(24).frame(width: 570)
    }
}
