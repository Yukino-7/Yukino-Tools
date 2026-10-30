import SwiftUI
import YukinoCore

private enum WorkSection: String, CaseIterable { case overview = "概览", records = "记录", report = "日报" }
enum WorkEditorKind: String { case project, task, log, issue }
struct WorkEditorTarget: Identifiable {
    var kind: WorkEditorKind
    var entityID: UUID?
    var id: String { kind.rawValue + (entityID?.uuidString ?? "new") }
}

struct WorkPilotView: View {
    @ObservedObject var model: WorkPilotModel
    @EnvironmentObject private var app: AppState
    @State private var section = WorkSection.overview
    @State private var day = Date()
    @State private var projectFilter: UUID?
    @State private var search = ""
    @State private var editor: WorkEditorTarget?
    @State private var deleting: WorkRecordEntry?
    @State private var rulesVisible = false
    @State private var managerVisible = false
    @State private var quickVisible = false
    @State private var drawerVisible = false
    @State private var drawerProjectID: UUID?
    @State private var quickText = ""
    @State private var quickFollowUp = false
    @State private var quickProjectID: UUID?
    @State private var onlyFollowUps = false
    @State private var showIgnored = false
    @State private var showUnassignedCodex = false
    @State private var reportText = ""
    @State private var regenerate = false
    @State private var sendingToCodex = false
    @FocusState private var quickFocused: Bool
    private var data: WorkPilotData { model.data }
    private var records: [WorkRecordEntry] {
        data.records(on: day).filter { projectFilter == nil || $0.projectID == projectFilter }
    }
    private var todaysRecords: [WorkRecordEntry] { records.filter { Calendar.current.isDate($0.date, inSameDayAs: day) } }
    private var pending: [WorkRecordEntry] {
        records.filter(\.isPending).sorted { lhs, rhs in
            if (lhs.status == .blocked) != (rhs.status == .blocked) { return lhs.status == .blocked }
            return lhs.date < rhs.date
        }
    }
    private var visibleProjects: [WorkProject] {
        data.projects.filter { (!$0.archived || $0.id == projectFilter) && (projectFilter == nil || $0.id == projectFilter) }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.ready {
                        ContentUnavailableView("工作区暂不可用", systemImage: "externaldrive.badge.exclamationmark", description: Text("原文件已保留，可从“更多”恢复备份。"))
                    } else {
                        switch section {
                        case .overview: overview
                        case .records: recordPage
                        case .report: reportPage
                        }
                    }
                }.padding(24)
            }
            Divider()
            focusBar
        }
        .background(Color.canvas)
        .overlay(alignment: .trailing) {
            if drawerVisible, let id = drawerProjectID {
                WorkProjectDetailView(model: model, projectID: id, day: day, close: { drawerVisible = false },
                                      edit: { editor = WorkEditorTarget(kind: .project, entityID: id) },
                                      showRecords: { projectFilter = id; search = ""; onlyFollowUps = false; section = .records; drawerVisible = false })
                .frame(width: 320).background(Color.canvas)
                .overlay(alignment: .leading) { Divider() }
                .shadow(color: .black.opacity(0.08), radius: 10, x: -4)
            }
        }
        .sheet(item: $editor) { WorkPilotEditor(model: model, target: $0, defaultDay: day, defaultProject: projectFilter) }
        .sheet(isPresented: $rulesVisible) { WorkPilotRulesView(model: model) }
        .sheet(isPresented: $managerVisible) { WorkProjectManagerView(model: model) }
        .sheet(isPresented: $quickVisible) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("记一笔").font(.title3.weight(.semibold)); Spacer(); Button("完成") { quickVisible = false }.keyboardShortcut(.cancelAction) }
                quickComposer
            }.padding(24).frame(width: 590).onAppear { quickFocused = true }
        }
        .alert("WorkPilot", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("删除这条记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) { if let deleting { model.deleteRecord(deleting) }; deleting = nil }
        } message: { Text("关联的任务完成记录也会一并移除。") }
        .alert("更新日报素材？", isPresented: $regenerate) {
            Button("取消", role: .cancel) {}
            Button("更新素材") { generateReport() }
        } message: { Text("会用最新记录替换当前素材，包括你补充的文字。") }
        .onAppear { loadReport(); quickProjectID = projectFilter ?? model.activeProject }
        .onChange(of: day) { _, _ in loadReport() }
        .onChange(of: section) { _, value in if value == .report { loadReport() } }
        .onChange(of: projectFilter) { _, value in quickProjectID = value }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Text("WorkPilot").font(.system(size: 19, weight: .semibold))
            Picker("工作台", selection: $section) {
                ForEach(WorkSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 250)
            Spacer(minLength: 8)
            if section != .report {
                Menu {
                    Button("全部项目") { projectFilter = nil }
                    ForEach(data.projects) { project in
                        Button(project.name + (project.archived ? "（已归档）" : "")) { projectFilter = project.id }
                    }
                    Divider()
                    Button("管理项目…") { managerVisible = true }
                } label: { Label(projectFilter.map { data.projectName($0) } ?? "全部项目", systemImage: "folder") }
                    .fixedSize().help("筛选当前项目；管理项目可创建、绑定仓库或归档。")
            }
            Menu {
                Button("管理项目…") { managerVisible = true }
                Button("自动计时设置…") { rulesVisible = true }.disabled(!model.ready)
                Divider()
                Button("备份记录…") { model.exportBackup() }.disabled(!model.ready)
                Button("从备份恢复…") { model.importBackup(); loadReport() }
                Button("打开本机保存位置") { model.revealStorage() }
            } label: { Label("更多", systemImage: "ellipsis") }.fixedSize()
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var dateSelector: some View {
        HStack(spacing: 8) {
            DatePicker("日期", selection: $day, displayedComponents: .date).labelsHidden().fixedSize()
            if !Calendar.current.isDateInToday(day) { Button("今天") { day = Date() } }
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(Calendar.current.isDateInToday(day) ? "今天" : "工作概览").font(.system(size: 23, weight: .semibold))
                dateSelector
                Spacer()
                Button { quickProjectID = projectFilter ?? model.activeProject; quickVisible = true } label: { Label("记一笔", systemImage: "square.and.pencil") }
                Button { section = .report } label: { Label("生成日报", systemImage: "doc.text") }.buttonStyle(.borderedProminent)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                WorkMetric(title: "今日记录", value: "\(todaysRecords.count)", symbol: "doc.text")
                WorkMetric(title: "待跟进", value: "\(pending.count)", symbol: "clock", color: WorkPilotStyle.amber, valueColor: WorkPilotStyle.amber)
                WorkMetric(title: "已完成", value: "\(todaysRecords.filter { $0.status == .done }.count)", symbol: "checkmark.circle", color: WorkPilotStyle.green)
                WorkMetric(title: "投入时间", value: duration(data.seconds(on: day, projectID: projectFilter)), symbol: "chart.bar")
            }
            HStack(alignment: .top, spacing: 20) {
                dashboardMain.frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                dashboardAside.frame(width: 280, alignment: .topLeading)
            }
        }
    }
    private var dashboardMain: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkCard {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading("今日进展", action: "查看全部") { onlyFollowUps = false; section = .records }
                    WorkModuleScroll(maxHeight: 230) {
                        if todaysRecords.isEmpty { smallEmpty("还没有记录，想到什么就记一笔。", symbol: "square.and.pencil") }
                        ForEach(todaysRecords) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(WorkPilotStyle.color(entry.status)).frame(width: 6, height: 6).padding(.top, 5)
                                Text(entry.date, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 45)
                                Text(entry.title).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                WorkStatusBadge(status: entry.status)
                            }.padding(.vertical, 5).contentShape(Rectangle()).onTapGesture { editor = target(for: entry) }
                        }
                    }
                }
            }
            discoveries
        }
    }
    private var dashboardAside: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading("待跟进", count: pending.count, action: "查看全部") { onlyFollowUps = true; section = .records }
                    WorkModuleScroll(maxHeight: 260, spacing: 4) {
                        if pending.isEmpty { smallEmpty("没有待跟进事项", symbol: "checkmark.circle") }
                        ForEach(pending) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Button { model.changeStatus(entry, .done) } label: {
                                    Image(systemName: "circle").foregroundStyle(WorkPilotStyle.color(entry.status))
                                        .font(.system(size: 15)).frame(width: 18, height: 18)
                                }.buttonStyle(.plain).accessibilityLabel("标记完成：\(entry.title)")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    if let project = entry.projectID { Text(data.projectName(project)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    .onTapGesture { editor = target(for: entry) }
                                if entry.status == .blocked { WorkStatusBadge(status: .blocked) }
                            }.padding(.vertical, 4)
                            if entry.id != pending.last?.id { Divider().padding(.leading, 26) }
                        }
                    }
                }
            }
            WorkCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading("项目概况", count: visibleProjects.count, action: "管理") { managerVisible = true }
                    WorkModuleScroll(maxHeight: 280) {
                        if visibleProjects.isEmpty {
                            smallEmpty("创建项目，关联记录和仓库。", symbol: "folder")
                            Button("创建项目") { editor = WorkEditorTarget(kind: .project) }
                        }
                        ForEach(visibleProjects) { project in
                            Button { drawerProjectID = project.id; drawerVisible = true } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder").font(.system(size: 15)).foregroundStyle(.secondary)
                                            .frame(width: 30, height: 30)
                                            .background(Color.canvas, in: RoundedRectangle(cornerRadius: 7))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(project.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Text(projectProgress(project.id)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                                    }
                                    WorkProgressBar(value: data.progress(for: project.id)).padding(.leading, 40).accessibilityHidden(true)
                                }.padding(.vertical, 4)
                            }.buttonStyle(.plain).help("查看项目详情")
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(project.name)，\(projectProgress(project.id))，查看项目详情")
                            if project.id != visibleProjects.last?.id { Divider().padding(.leading, 40) }
                        }
                    }
                }
            }
        }
    }

    private var discoveries: some View {
        let values = data.discoveries.filter {
            ($0.state == .pending || (showIgnored && $0.state == .ignored)) && Calendar.current.isDate($0.commit.date, inSameDayAs: day) &&
            (projectFilter == nil || $0.projectID == projectFilter)
        }.sorted { $0.commit.date > $1.commit.date }
        let codexItems = data.codexDiscoveries.filter {
            ($0.state == .pending || (showIgnored && $0.state == .ignored)) && Calendar.current.isDate($0.activity.date, inSameDayAs: day) &&
            (projectFilter == nil || $0.projectID == projectFilter)
        }.sorted { $0.activity.date > $1.activity.date }
        let visibleCodex = codexItems.filter { $0.projectID != nil || showUnassignedCodex }
        return WorkCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("自动发现").font(.system(size: 14, weight: .semibold))
                    if model.scanningDiscoveries { ProgressView().controlSize(.small) }
                    Spacer()
                    Button { Task { await model.scanDiscoveries(day: day) } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.scanningDiscoveries).help("扫描所选日期的 Git 提交和 Codex 工作会话")
                    Menu {
                        Toggle("显示已忽略", isOn: $showIgnored)
                        Toggle("显示未匹配项目的 Codex 会话", isOn: $showUnassignedCodex)
                        if values.contains(where: { $0.state == .pending }) || visibleCodex.contains(where: { $0.state == .pending }) {
                            Button("全部加入记录") {
                                model.update { data in
                                    for item in values where item.state == .pending { data.setDiscovery(item.id, state: .accepted) }
                                    for item in visibleCodex where item.state == .pending { data.setCodexDiscovery(item.id, state: .accepted) }
                                }
                            }
                        }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }
                WorkModuleScroll(maxHeight: 400) {
                    if values.isEmpty && visibleCodex.isEmpty { smallEmpty("暂无新发现。自动扫描 Git 和 Codex 工作会话。", symbol: "sparkle.magnifyingglass") }
                    ForEach(values) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "point.3.connected.trianglepath.dotted").font(.title3).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.commit.subject).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Text("\(data.projectName(item.projectID)) · \(item.commit.hash.prefix(8)) · \(item.commit.fileCount) 个文件")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            HStack {
                                Spacer()
                                Button(item.state == .ignored ? "恢复" : "忽略") { model.update { $0.setDiscovery(item.id, state: item.state == .ignored ? .pending : .ignored) } }
                                Button("加入记录") { model.update { $0.setDiscovery(item.id, state: .accepted) } }
                            }.controlSize(.small)
                        }.padding(.vertical, 5)
                    }
                    if !visibleCodex.isEmpty {
                        Text("Codex 工作会话").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        ForEach(visibleCodex) { item in WorkCodexDiscoveryRow(model: model, item: item) }
                    }
                    if !showUnassignedCodex, codexItems.contains(where: { $0.projectID == nil }) {
                        Button("另有 \(codexItems.filter { $0.projectID == nil }.count) 条未匹配项目的 Codex 会话，查看…") { showUnassignedCodex = true }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.discoveryStatus).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    ForEach(visibleProjects.filter { $0.repositoryPath != nil }) { project in
                        if let tree = model.workingTrees[project.id], !tree.files.isEmpty {
                            DisclosureGroup("\(project.name) · \(tree.files.count) 项未提交变更") {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("当前工作区状态，不自动写入日报。").foregroundStyle(.secondary)
                                    ForEach(Array(tree.files.enumerated()), id: \.offset) { _, file in Text("\(file.status)  \(file.path)").textSelection(.enabled) }
                                }.font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            }.font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var recordPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                dateSelector
                Spacer()
                Toggle("只看待跟进", isOn: $onlyFollowUps).toggleStyle(.checkbox).font(.caption)
                TextField("搜索记录", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 210)
            }
            WorkCard { quickComposer }
            WorkCard {
                VStack(alignment: .leading, spacing: 0) {
                    let values = (onlyFollowUps ? pending : records).filter {
                        search.isEmpty || "\($0.title) \($0.detail)".localizedCaseInsensitiveContains(search)
                    }
                    if values.isEmpty { smallEmpty("写一句就能留下进展，后续需要处理就勾选“待跟进”。", symbol: "square.and.pencil") }
                    ForEach(values) { entry in
                        recordRow(entry)
                        if entry.id != values.last?.id { Divider() }
                    }
                }
            }
        }
    }
    private var quickComposer: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("做了什么，或接下来要做什么…", text: $quickText, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(2...6).font(.system(size: 14)).focused($quickFocused)
            HStack(spacing: 12) {
                Picker("项目", selection: $quickProjectID) {
                    Text("不选项目").tag(nil as UUID?)
                    ForEach(data.projects.filter { !$0.archived || $0.id == quickProjectID }) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(maxWidth: 190)
                Toggle("待跟进", isOn: $quickFollowUp).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button("记录  ⌘↵") { capture() }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(quickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    private func recordRow(_ entry: WorkRecordEntry) -> some View {
        let supplement: String = {
            guard case .task(let task) = entry else { return "" }
            return data.logs.filter { $0.taskID == task.id && $0.result != "已完成" && !task.detail.contains($0.result) }.map(\.result).joined(separator: "\n")
        }()
        return WorkRecordRow(entry: entry, projectName: entry.projectID.map { data.projectName($0) }, supplementalDetail: supplement,
                             toggle: { model.changeStatus(entry, entry.status == .done ? .todo : .done) },
                             edit: { editor = target(for: entry) }, delete: { deleting = entry },
                             changeStatus: { model.changeStatus(entry, $0) })
    }
    private func capture() {
        let date = Calendar.current.isDateInToday(day) ? Date() : day
        if model.update({ $0.capture(quickText, followUp: quickFollowUp, projectID: quickProjectID, at: date) }) {
            quickText = ""; quickFollowUp = false; quickFocused = true
            if quickVisible { quickVisible = false }
        }
    }

    private var reportPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                DatePicker("日报日期", selection: $day, displayedComponents: .date).fixedSize()
                Spacer()
                Button("更新素材") {
                    if data.reports.contains(where: { Calendar.current.isDate($0.day, inSameDayAs: day) }) { regenerate = true }
                    else { generateReport() }
                }
                Button("复制") { app.copy(reportText) }
                Button {
                    sendingToCodex = true
                    Task {
                        defer { sendingToCodex = false }
                        if await model.sendToCodex(material: reportText, day: day) { app.notify("已准备 Codex 对话，点击发送生成日报") }
                    }
                } label: { Label(sendingToCodex ? "正在打开…" : "发送到 Codex 生成", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.borderedProminent).disabled(sendingToCodex || reportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("汇总当天全部项目的记录，可直接补充背景或结果。").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { reportText }, set: { if model.saveReport(day: day, markdown: $0) { reportText = $0 } }))
                .font(.system(size: 13)).scrollContentBackground(.hidden).scrollIndicators(.never)
                .padding(16).frame(minHeight: 400)
                .background(Color.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.hairline, lineWidth: 0.5))
            Text("发送内容只有 skill 提示和日报原文；在 Codex 点“发送”生成正文。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var focusBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "clock").foregroundStyle(.secondary)
            Text(model.trackingLabel).font(.caption).lineLimit(1)
            Spacer()
            if model.manualProject != nil { Button("结束专注") { model.focus(nil) } }
            else {
                Menu("开始专注") {
                    ForEach(data.projects.filter { !$0.archived }) { project in Button(project.name) { model.focus(project.id) } }
                    if !data.projects.contains(where: { !$0.archived }) { Text("请先创建项目") }
                }.fixedSize().disabled(!model.ready)
            }
            Toggle("自动计时", isOn: Binding(get: { model.automatic }, set: { model.setAutomatic($0) }))
                .toggleStyle(.switch).controlSize(.mini).font(.caption).fixedSize().disabled(!model.ready)
                .help("按应用与项目的关联统计用时；在“更多”里设置。")
        }.controlSize(.small).padding(.horizontal, 24).padding(.vertical, 10)
    }
    private func loadReport() { reportText = data.reports.first { Calendar.current.isDate($0.day, inSameDayAs: day) }?.markdown ?? data.report(for: day) }
    private func generateReport() { let text = data.report(for: day); if model.saveReport(day: day, markdown: text) { reportText = text } }
    private func sectionHeading(_ text: String, count: Int? = nil, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 7) {
            Text(text).font(.system(size: 14, weight: .semibold))
            if let count {
                Text("\(count)").font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.canvas, in: Capsule())
            }
            Spacer()
            Button(action, action: perform).buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private func smallEmpty(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
    }
    private func projectProgress(_ id: UUID) -> String {
        let items = data.allRecords.filter { $0.projectID == id && $0.status != nil }
        return items.isEmpty ? "暂无待跟进事项" : "\(items.filter { $0.status == .done }.count)/\(items.count) 项完成"
    }
    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
    private func target(for entry: WorkRecordEntry) -> WorkEditorTarget {
        switch entry {
        case .task(let task): WorkEditorTarget(kind: .task, entityID: task.id)
        case .log(let log): WorkEditorTarget(kind: .log, entityID: log.id)
        case .issue(let issue): WorkEditorTarget(kind: .issue, entityID: issue.id)
        }
    }
}
