import SwiftUI
import AppKit
import YukinoCore

struct AIAPIDebugView: View {
    @ObservedObject var model: AIAPIDebugViewModel
    @ObservedObject var curls: CurlViewModel
    @EnvironmentObject private var state: AppState
    @AppStorage("curlFavoritesVisible") private var favoritesVisible = true
    @State private var favoritesPopover = false
    @State private var conversion = false
    @State private var settings = false
    @State private var pendingFavorite: CurlFavorite?
    @State private var confirmLoad = false
    @State private var tab = "结果"
    @State private var search = ""
    @State private var hideHeartbeat = true
    @State private var follow = true
    @State private var requestVisible = true
    @State private var renderMarkdown = true
    @State private var processExpansion: [String: Bool] = [:]
    @State private var expanded = Set<Int>()
    private var tabs: [String] { model.isSSE ? ["结果", "事件", "原始流", "响应头"] : ["结果", "原始流", "响应头"] }

    var body: some View {
        GeometryReader { geometry in
            let sidebar = geometry.size.width >= 1000
            HStack(spacing: 0) {
                if sidebar && favoritesVisible {
                    favorites.frame(width: 200)
                    Divider()
                }
                VStack(alignment: .leading, spacing: 14) {
                    toolbar(sidebar: sidebar)
                    GeometryReader { area in
                        if area.size.width >= 700 {
                            HSplitView {
                                requestPanel.frame(minWidth: 280, idealWidth: area.size.width * 0.43, maxWidth: area.size.width * 0.62)
                                responsePanel.frame(minWidth: 300, maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 10) {
                                Picker("工作区", selection: $requestVisible) { Text("请求").tag(true); Text("响应").tag(false) }
                                    .pickerStyle(.segmented).frame(width: 180)
                                if requestVisible { requestPanel } else { responsePanel }
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                        Text(curls.notice ?? "仅主动收藏才保存请求；发送后联系指定接口。")
                            .lineLimit(2).textSelection(.enabled)
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(16)
            }.background(Color.canvas)
        }
        .onAppear { synchronizeCurl(); model.scheduleValidation() }
        .onDisappear { model.leave() }
        .onChange(of: model.running) { _, running in if running { processExpansion = [:]; expanded = [] } }
        .onChange(of: model.command) { _, _ in synchronizeCurl(); model.scheduleValidation() }
        .onChange(of: model.shell) { _, _ in synchronizeCurl(); model.scheduleValidation() }
        .onChange(of: model.automaticShell) { _, _ in synchronizeCurl(); model.scheduleValidation() }
        .onChange(of: model.mode) { _, _ in model.reparse() }
        .onChange(of: model.fieldPath) { _, _ in model.reparse() }
        .onChange(of: model.cumulative) { _, _ in model.reparse() }
        .onChange(of: model.isSSE) { _, value in if !value && tab == "事件" { tab = "结果" } }
        .sheet(isPresented: $conversion) { CurlConversionSheet(model: curls) }
        .confirmationDialog("载入收藏会替换当前未保存的命令。", isPresented: $confirmLoad, titleVisibility: .visible) {
            Button("载入收藏", role: .destructive) { if let pendingFavorite { load(pendingFavorite) }; pendingFavorite = nil }
            Button("取消", role: .cancel) { pendingFavorite = nil }
        }
    }
    private func synchronizeCurl() {
        curls.inputCommand = model.command
        curls.sourceShell = model.automaticShell ? CurlCommandParser.detectedShell(model.command) : model.shell
    }
    private func load(_ favorite: CurlFavorite) {
        guard !model.running else { return }
        curls.load(favorite); model.loadFavorite(favorite); favoritesPopover = false
    }
    private func requestLoad(_ favorite: CurlFavorite) {
        guard !model.running, curls.selectedID != favorite.id else { return }
        if curls.hasUnsavedInput { pendingFavorite = favorite; confirmLoad = true }
        else { load(favorite) }
    }
    private var favorites: some View {
        CurlFavoritesSidebar(model: curls, busy: model.running, onLoad: requestLoad)
    }
    private func toolbar(sidebar: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                if sidebar { favoritesVisible.toggle() } else { favoritesPopover.toggle() }
            } label: { Image(systemName: "sidebar.left") }
                .help("我的收藏").accessibilityLabel("我的 cURL 收藏")
                .popover(isPresented: $favoritesPopover) { favorites.frame(width: 260, height: 420) }
            Text(curls.selected?.name ?? "新请求").font(.system(size: 13, weight: .medium))
                .lineLimit(1).frame(maxWidth: 150, alignment: .leading).layoutPriority(-1)
            if curls.modified { Text("有修改").font(.system(size: 10)).foregroundStyle(.secondary) }
            CurlFavoriteActions(model: curls, prepare: synchronizeCurl).disabled(model.running)
            Spacer(minLength: 0)
            Button {
                synchronizeCurl(); curls.scheduleImport(); conversion = true
            } label: { Label("转换", systemImage: "arrow.left.arrow.right") }
                .disabled(model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).help("转换 cURL 终端格式")
            Menu {
                Button("载入流式请求示例") { curls.clear(); model.loadExample() }
                Button("载入 JSON 请求示例") { curls.clear(); model.loadJSONExample() }
                Divider()
                Button("体验 SSE 响应") { model.playDemo(); tab = "结果"; requestVisible = false }
                Button("体验 JSON 响应") { model.playJSONDemo(); tab = "结果"; requestVisible = false }
                Button("导入 SSE 文件…") { model.importStream(); requestVisible = false }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                .disabled(model.running).help("示例、演示与导入")
            Button { settings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .help("请求与解析设置").accessibilityLabel("请求与解析设置")
                .popover(isPresented: $settings) { requestSettings }
            Button {
                model.send(); requestVisible = false; tab = "结果"
            } label: { Label(model.running ? "接收中" : "发送请求", systemImage: "paperplane.fill") }
                .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(!model.canSend)
            if model.running {
                Button { model.stop() } label: { Image(systemName: "stop.fill") }
                    .help("停止接收并保留已有内容").accessibilityLabel("停止请求")
            }
        }.controlSize(.regular)
    }
    private var requestPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("请求").font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        curls.clear(); model.command = text; model.automaticShell = true
                    }
                } label: { Image(systemName: "doc.on.clipboard") }.help("从剪贴板粘贴 cURL").accessibilityLabel("粘贴 cURL")
                Button { curls.clear(); model.clear() } label: { Image(systemName: "trash") }
                    .help("清空请求与响应").accessibilityLabel("清空请求与响应").disabled(model.running)
            }.buttonStyle(.borderless).foregroundStyle(.secondary).padding(12)
            Divider()
            ZStack(alignment: .topLeading) {
                CodeEditor(text: $model.command).accessibilityLabel("cURL 请求命令")
                if model.command.isEmpty {
                    Text("粘贴 cURL…").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                        .padding(.leading, 38).padding(.top, 14).allowsHitTesting(false)
                }
            }.frame(minHeight: 150, maxHeight: .infinity)
            if model.command.contains("{{API_KEY}}") {
                Divider()
                SecureField("API Key · 仅本次会话", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder).padding(12).accessibilityLabel("API Key")
            }
            if let message = model.inputError {
                Divider()
                Text(message).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            } else if !model.endpoint.isEmpty {
                Divider()
                Label(model.endpoint, systemImage: "checkmark.circle").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).padding(12)
            }
        }.background(Color.panel, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.hairline, lineWidth: 0.7))
    }
    private var requestSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("请求与解析设置").font(.system(size: 14, weight: .medium))
            Toggle("自动识别 cURL 来源", isOn: $model.automaticShell).toggleStyle(.checkbox)
            if !model.automaticShell {
                Picker("命令来源", selection: $model.shell) {
                    ForEach(CurlShell.allCases, id: \.self) { Text($0.shortName).tag($0) }
                }
            }
            Picker("SSE 内容解析", selection: $model.mode) {
                ForEach(AIStreamMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Text("响应格式自动识别；这里仅影响 SSE 事件中的正文提取。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if model.mode == .generic {
                TextField("正文路径，例如 data.content", text: $model.fieldPath).textFieldStyle(.roundedBorder)
                Toggle("字段返回累计全文", isOn: $model.cumulative).toggleStyle(.checkbox)
            }
            Divider()
            HStack {
                Text("无数据超时（秒）")
                Spacer()
                TextField("秒", value: $model.idleTimeout, format: .number).frame(width: 65)
            }
            HStack {
                Text("总时限（秒）")
                Spacer()
                TextField("秒", value: $model.totalTimeout, format: .number).frame(width: 65)
            }
            Text("0 表示不限，cURL 显式超时优先。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.font(.system(size: 12)).textFieldStyle(.roundedBorder).padding(20).frame(width: 340)
    }
    private var responsePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            responseStatus
            Divider()
            HStack(spacing: 2) {
                ForEach(tabs, id: \.self) { name in
                    Button { tab = name } label: {
                        Text(tabTitle(name)).font(.system(size: 12, weight: tab == name ? .medium : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 11)
                            .foregroundStyle(tab == name ? Color.accentColor : .secondary)
                            .overlay(alignment: .bottom) { Color.accentColor.opacity(tab == name ? 1 : 0).frame(height: 2) }
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if model.isSSE {
                    Toggle(isOn: $follow) { Image(systemName: "arrow.down.to.line") }.toggleStyle(.button).help("自动跟随最新内容").controlSize(.small)
                }
            }.padding(.horizontal, 8)
            Divider()
            if !model.hasResponse && !model.running { emptyResponse }
            else {
                switch tab {
                case "事件": eventList
                case "原始流": StreamTextView(text: model.rawText, follow: model.isSSE && follow).frame(maxHeight: .infinity)
                case "响应头": StreamTextView(text: model.headers.isEmpty ? "等待响应头…" : model.headers, follow: false).frame(maxHeight: .infinity)
                default:
                    if model.isSSE { result }
                    else if let json = model.formattedJSON {
                        CodeEditor(text: .constant(json), editable: false, highlightJSON: true).accessibilityLabel("格式化 JSON 响应")
                    } else if !model.rawText.isEmpty {
                        StreamTextView(text: model.rawText, follow: false).accessibilityLabel("响应正文")
                    } else {
                        Text(model.running ? "等待响应…" : "响应体为空")
                            .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            if let error = model.error {
                ScrollView {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(maxHeight: 75).background(Color.orange.opacity(0.06))
            }
            Divider()
            HStack {
                Text(model.demo ? "本地演示 · \(model.responseFormat)" : model.responseFormat)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { state.copy(model.isSSE ? model.accumulator.text : model.responseText) } label: { Image(systemName: "doc.on.doc") }.help("复制响应正文")
                Menu {
                    Button("响应正文…") { model.export("正文") }
                    Button("原始响应…") { model.export("原始流") }
                    if model.isSSE { Button("事件 JSON…") { model.export("事件") } }
                } label: { Image(systemName: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize().help("导出响应")
            }.buttonStyle(.borderless).disabled(model.byteCount == 0).padding(12)
        }.background(Color.panel, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.hairline, lineWidth: 0.7))
    }
    private func tabTitle(_ name: String) -> String {
        if name == "结果" { return model.isSSE ? "结果" : model.formattedJSON != nil ? "JSON" : "响应" }
        if name == "原始流" { return model.isSSE ? "原始流" : "原文" }
        if name == "事件", model.messageCount > 0 { return "事件 \(model.messageCount)" }
        return name
    }
    private var statusColor: Color { model.error != nil ? .orange : model.running ? Color.accentColor : model.hasResponse ? .green : .secondary }
    private var responseStatus: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("响应").font(.system(size: 12, weight: .medium))
                Spacer()
                if model.running { ProgressView().controlSize(.mini) }
                Circle().fill(statusColor).frame(width: 5, height: 5)
                Text(model.httpStatus.isEmpty ? model.status : model.httpStatus + " · " + model.status)
                    .font(.system(size: 10)).foregroundStyle(statusColor).lineLimit(1)
            }
            if model.running || model.hasResponse {
                HStack(spacing: 12) {
                    Text("首字节 \(time(model.firstByte))")
                    Text(String(format: "耗时 %.2f s", model.elapsed))
                    Text(ByteCountFormatter.string(fromByteCount: Int64(model.byteCount), countStyle: .file))
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                if model.isSSE {
                    HStack(spacing: 12) {
                        Text("首事件 \(time(model.firstEvent))")
                        Text("首正文 \(time(model.firstText))")
                    }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                if !model.responseEndpoint.isEmpty {
                    Text(model.responseEndpoint).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
        }.padding(12)
    }
    private func time(_ value: TimeInterval?) -> String { value.map { $0 < 1 ? String(format: "%.0f ms", $0 * 1000) : String(format: "%.2f s", $0) } ?? "—" }
    private var emptyResponse: some View {
        VStack(spacing: 8) {
            Text("等待响应").font(.system(size: 14, weight: .medium))
            Text("支持 JSON、文本和 SSE 流式返回")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var result: some View {
        GeometryReader { geometry in
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.accumulator.outputs.isEmpty {
                        HStack {
                            Image(systemName: "sparkles").font(.system(size: 15)).foregroundStyle(Color.accentColor)
                                .frame(width: 34, height: 34).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("助手回答").font(.system(size: 13, weight: .semibold))
                                Text(model.accumulator.model.isEmpty ? (model.running ? "实时生成 · Markdown" : "回答内容 · Markdown") : model.accumulator.model)
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Picker("展示方式", selection: $renderMarkdown) {
                                Text("渲染").tag(true)
                                Text("源码").tag(false)
                            }.pickerStyle(.segmented).frame(width: 106).controlSize(.small)
                        }
                    }
                    if model.accumulator.outputs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.running ? "等待正文增量…" : "暂无可提取正文").font(.system(size: 14, weight: .medium))
                            Text("可在「事件」查看完整 data；自定义接口可选择通用 SSE 并填写正文路径。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(.vertical, 24)
                    }
                    ForEach(model.accumulator.outputs) { output in
                        VStack(alignment: .leading, spacing: 12) {
                            if model.accumulator.outputs.count > 1 { Text(output.id.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                            if !output.thinkingText.isEmpty {
                                DisclosureGroup(isExpanded: Binding(
                                    get: { processExpansion[output.id] ?? (model.running && output.answerText.isEmpty) },
                                    set: { processExpansion[output.id] = $0 }
                                )) {
                                    Text(output.thinkingText).font(.system(size: 12)).lineSpacing(4)
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                                } label: {
                                    HStack(spacing: 7) {
                                        Label(model.accumulator.detected == .generic ? "执行过程 · 服务端返回" : "思考过程 · 服务端返回", systemImage: "text.bubble")
                                        if model.running && output.answerText.isEmpty {
                                            Text("实时接收中").foregroundStyle(Color.accentColor)
                                        }
                                    }
                                }.font(.system(size: 11)).foregroundStyle(.secondary)
                                    .padding(12).background(Color.accentColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                            }
                            if model.running && output.answerText.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(output.thinkingText.isEmpty ? "等待正文增量…" : "正在执行，等待服务端返回正式正文…")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                            if renderMarkdown {
                                MarkdownReader(blocks: model.renderedAnswers[output.id] ?? [], embedded: true, availableWidth: max(0, min(geometry.size.width, 900) - 48))
                            } else if !output.text.isEmpty {
                                Text(output.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(output.tools.keys.sorted(), id: \.self) { key in
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(output.toolNames[key] ?? "工具调用 \(key)", systemImage: "wrench.and.screwdriver").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                                    Text(output.tools[key] ?? "").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                            }
                            if !output.finishReason.isEmpty { Label(model.running ? output.finishReason : "回答完成 · " + output.finishReason, systemImage: "checkmark.circle")
                                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 8) }
                        }
                    }
                    if !model.usage.isEmpty { DisclosureGroup("Token 用量 · 服务端返回") { Text(model.usage).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }.font(.system(size: 11)).foregroundStyle(.secondary) }
                    if !model.warnings.isEmpty {
                        DisclosureGroup("请求与解析说明 · \(model.warnings.count)") {
                            VStack(alignment: .leading, spacing: 7) { ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, item in Text(item).font(.system(size: 11)).textSelection(.enabled) } }.padding(.top, 8)
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if model.accumulator.malformedCount > 0 { Text("\(model.accumulator.malformedCount) 条 data 看起来是 JSON 但解析失败；原文已保留在事件列表。").font(.system(size: 10)).foregroundStyle(.secondary) }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
            }.onChange(of: model.revision) { _, _ in if follow { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
        }
    }
    private var eventList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索事件类型或 data", text: $search).textFieldStyle(.plain)
                Toggle("隐藏心跳", isOn: $hideHeartbeat).toggleStyle(.checkbox).fixedSize()
            }.font(.system(size: 11)).padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.events.filter { (!hideHeartbeat || !$0.isHeartbeat) && (search.isEmpty || ($0.name + $0.data).localizedCaseInsensitiveContains(search)) }) { event in
                            VStack(alignment: .leading, spacing: 9) {
                                Button {
                                    if expanded.contains(event.id) { expanded.remove(event.id) } else { expanded.insert(event.id) }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: expanded.contains(event.id) ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 10)
                                        Text(String(format: "%03d", event.id)).foregroundStyle(.tertiary)
                                        Text(event.name).foregroundStyle(Color.accentColor).lineLimit(1)
                                        Spacer()
                                        Text(String(format: "+%.3fs", event.time)).foregroundStyle(.secondary)
                                    }.font(.system(size: 11, design: .monospaced)).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if expanded.contains(event.id) {
                                    if !event.eventID.isEmpty { Text("id: \(event.eventID)").font(.system(size: 10)).foregroundStyle(.secondary) }
                                    Text(pretty(event.data)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    Button("复制 data") { state.copy(event.data) }.font(.system(size: 10))
                                } else { Text(event.data.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 18) }
                            }.padding(12)
                            Divider()
                        }
                        Color.clear.frame(height: 1).id("event-bottom")
                    }
                }.onChange(of: model.revision) { _, _ in if follow && expanded.isEmpty { proxy.scrollTo("event-bottom", anchor: .bottom) } }
            }
        }
    }
    private func pretty(_ value: String) -> String { (try? JSONService.transform(value)) ?? value }
}

/// Append-only updates preserve selection and avoid re-highlighting the full stream each frame.
private struct StreamTextView: NSViewRepresentable {
    let text: String
    let follow: Bool
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let view = NSTextView(); view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular); view.textColor = .labelColor; view.drawsBackground = false
        view.textContainerInset = NSSize(width: 16, height: 16); view.isVerticallyResizable = true
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        scroll.documentView = view; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        if text.hasPrefix(view.string) {
            view.textStorage?.append(NSAttributedString(string: String(text.dropFirst(view.string.count)), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor]))
        } else { view.string = text }
        if follow { view.scrollToEndOfDocument(nil) }
    }
}
