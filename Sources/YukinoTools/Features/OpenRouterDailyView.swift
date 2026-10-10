import SwiftUI
import UniformTypeIdentifiers
import YukinoCore

@MainActor final class OpenRouterDailyModel: ObservableObject {
    @Published var entries: [DailyReportEntry] = []
    @Published var selectedDate: String?
    @Published var markdown = ""
    @Published var blocks: [MarkdownBlock] = []
    @Published var error: String?
    @Published var notice: String?
    @Published var working = false
    @Published var activity = ""
    @Published var readError: String?
    let store = DailyReportStore()
    private var generation: Task<Void, Never>?

    var hasToday: Bool { entries.contains { $0.dateKey == OpenRouterReportService.dateKey() } }
    func refresh(select date: String? = nil) async {
        do {
            entries = try await store.entries()
            if let date, entries.contains(where: { $0.dateKey == date }) { selectedDate = date }
            else if !entries.contains(where: { $0.dateKey == selectedDate }) {
                selectedDate = entries.first(where: { $0.dateKey == OpenRouterReportService.dateKey() })?.dateKey ?? entries.first?.dateKey
            }
        } catch { self.error = error.localizedDescription }
    }
    func loadSelected() async {
        markdown = ""; blocks = []; readError = nil
        guard let date = selectedDate else { return }
        do {
            let text = try await store.markdown(for: date)
            let parsed = await Task.detached(priority: .userInitiated) { MarkdownDocument.openRouterReadingBlocks(text) }.value
            guard !Task.isCancelled, selectedDate == date else { return }
            markdown = text; blocks = parsed
        } catch {
            guard !Task.isCancelled, selectedDate == date else { return }
            self.error = error.localizedDescription
            readError = error.localizedDescription
        }
    }
    func startGeneration(replacing: Bool) {
        guard !working else { return }
        working = true; error = nil; notice = nil; activity = "正在获取模型列表和周榜…"
        generation = Task {
            defer { working = false; generation = nil }
            do {
                let previous = try await store.previous(before: OpenRouterReportService.dateKey())
                let report = try await OpenRouterReportService.generate(previous: previous)
                try Task.checkCancellation()
                activity = "正在保存 Markdown…"
                let entry = try await store.save(report, replacing: replacing)
                await refresh(select: entry.dateKey)
                // Replacing the selected date does not trigger task(id:), so reload explicitly.
                await loadSelected()
                notice = report.snapshot.warnings.isEmpty ? "今日日报已生成" : "日报已保存，数据提示见正文"
            } catch is CancellationError { notice = "已取消生成" }
            catch { self.error = error.localizedDescription }
        }
    }
    func cancel() { generation?.cancel() }
    func importHistory(_ directory: URL) async {
        guard !working else { return }
        working = true; activity = "正在导入历史 Markdown…"; error = nil; notice = nil
        defer { working = false }
        do {
            let result = try await store.importDirectory(directory)
            await refresh()
            notice = "导入 \(result.imported) 份，跳过 \(result.skipped) 份已有报告"
            if !result.errors.isEmpty { error = result.errors.joined(separator: "\n") }
        } catch { self.error = error.localizedDescription }
    }
}

struct OpenRouterDailyView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = OpenRouterDailyModel()
    @State private var source = false
    @State private var confirmUpdate = false
    @State private var historyExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if model.working { Text(model.activity).font(.system(size: 12)).foregroundStyle(.secondary) }
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.system(size: 12)).textSelection(.enabled).lineLimit(4)
                    Spacer()
                    Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭错误提示")
                }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if let notice = model.notice { Text(notice).font(.system(size: 12)).foregroundStyle(.secondary) }
            GeometryReader { geometry in
                HStack(spacing: 16) {
                    if historyExpanded { history.frame(width: 150) }
                    VStack(spacing: 0) {
                        HStack {
                            Button { historyExpanded.toggle() } label: { Image(systemName: "sidebar.left") }
                                .help(historyExpanded ? "收起历史日报列表" : "展开历史日报列表")
                                .accessibilityLabel(historyExpanded ? "收起历史日报" : "展开历史日报")
                            Text(model.selectedDate.map { $0 + ".md" } ?? "Markdown").font(.system(size: 12, weight: .medium))
                            if model.hasToday && model.selectedDate != OpenRouterReportService.dateKey() {
                                Button("回到今日") { model.selectedDate = OpenRouterReportService.dateKey() }
                                    .font(.system(size: 11))
                            }
                            Spacer()
                            Picker("展示方式", selection: $source) { Text("阅读").tag(false); Text("源码").tag(true) }
                                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                            Button { state.copy(model.markdown) } label: { Image(systemName: "doc.on.doc") }.help("复制 Markdown").accessibilityLabel("复制 Markdown").disabled(model.markdown.isEmpty)
                            Button { exportReport() } label: { Image(systemName: "square.and.arrow.up") }.help("导出 .md").accessibilityLabel("导出 Markdown").disabled(model.markdown.isEmpty)
                        }.padding(12)
                        Divider()
                        if model.selectedDate == nil {
                            ContentUnavailableView("还没有日报", systemImage: "doc.text", description: Text("生成今日日报，或导入已有的 YYYY-MM-DD.md 历史目录。"))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if model.markdown.isEmpty {
                            ContentUnavailableView(model.readError == nil ? "正在读取报告" : "无法读取报告", systemImage: "doc.text", description: Text(model.readError ?? "历史报告保存在本机。"))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if source {
                            CodeEditor(text: .constant(model.markdown), editable: false).id(model.selectedDate)
                        } else {
                            MarkdownReader(blocks: model.blocks).id(model.selectedDate)
                        }
                    }
                    .background(Color.panel, in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.hairline, lineWidth: 0.5))
                }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
            Text("Asia/Shanghai 日期 · 历史可离线阅读 · 榜单自适应布局 · 全量模型表可横向滚动")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(28).background(Color.canvas)
        .task { await model.refresh() }
        .task(id: model.selectedDate) { await model.loadSelected() }
        .onDisappear { model.cancel() }
        .confirmationDialog("更新今日报告？", isPresented: $confirmUpdate, titleVisibility: .visible) {
            Button("保存旧版本并更新") { model.startGeneration(replacing: true) }
            Button("取消", role: .cancel) {}
        } message: { Text("会重新获取当前数据；现有 Markdown 和快照会保留在 Revisions 目录。") }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenRouter 日报").font(.system(size: 28, weight: .semibold))
            HStack(spacing: 10) {
                Text("免费模型变化、周调用量与能力列表 · Markdown 历史")
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    .help("免费模型变化、周调用量与能力列表 · Markdown 历史")
                Spacer(minLength: 16)
                Button(model.hasToday ? "更新今日日报" : "生成今日日报") {
                    if model.hasToday { confirmUpdate = true } else { model.startGeneration(replacing: false) }
                }.buttonStyle(.borderedProminent).disabled(model.working).fixedSize()
                Button("导入历史", systemImage: "square.and.arrow.down") { importHistory() }
                    .disabled(model.working).fixedSize()
                Button("刷新", systemImage: "arrow.clockwise") { Task { await model.refresh(); await model.loadSelected() } }
                    .disabled(model.working).fixedSize()
                if model.working {
                    ProgressView().controlSize(.small)
                    Button("取消") { model.cancel() }.disabled(!model.activity.contains("获取"))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("历史日报").font(.system(size: 12, weight: .semibold))
                Spacer(); Text("\(model.entries.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).padding(.top, 12)
            List(selection: $model.selectedDate) {
                ForEach(model.entries) { entry in
                    Label(entry.dateKey, systemImage: "doc.text").font(.system(size: 11)).tag(entry.dateKey)
                }
            }.listStyle(.plain)
            Button("报告目录", systemImage: "folder") { NSWorkspace.shared.open(DailyReportStore.defaultDirectory) }
                .font(.system(size: 11)).buttonStyle(.plain).padding(10)
        }.background(Color.panel, in: RoundedRectangle(cornerRadius: 12))
    }
    private func importHistory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "导入日报"; panel.message = "复制日期命名的 Markdown 到 App；已有日期会跳过，原文件保持不变。"
        if panel.runModal() == .OK, let url = panel.url { Task { await model.importHistory(url) } }
    }
    private func exportReport() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = (model.selectedDate ?? "report") + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do { try Data(model.markdown.utf8).write(to: url, options: .atomic); state.notify("Markdown 已导出") }
            catch { model.error = error.localizedDescription }
        }
    }
}
