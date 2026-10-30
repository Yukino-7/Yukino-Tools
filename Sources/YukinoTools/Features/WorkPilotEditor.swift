import AppKit
import SwiftUI
import YukinoCore

struct WorkPilotEditor: View {
    @ObservedObject var model: WorkPilotModel
    let target: WorkEditorTarget
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var detail = ""
    @State private var result = ""
    @State private var solution = ""
    @State private var followUp = ""
    @State private var projectID: UUID?
    @State private var day: Date
    @State private var due = Date()
    @State private var hasDue = false
    @State private var priority = 1
    @State private var status = WorkStatus.todo
    @State private var logStatus: WorkStatus?
    @State private var loaded = false
    @State private var repository = ""
    @State private var authorEmail = ""
    @State private var checkingRepository = false
    @State private var localError: String?
    @State private var moreExpanded = false
    init(model: WorkPilotModel, target: WorkEditorTarget, defaultDay: Date, defaultProject: UUID?) {
        self.model = model; self.target = target
        _day = State(initialValue: defaultDay); _projectID = State(initialValue: defaultProject)
    }
    private var noun: String {
        switch target.kind { case .project: "项目"; case .task, .log, .issue: "记录" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(target.entityID == nil ? "新建" : "编辑")\(noun)").font(.title2.weight(.semibold)).padding(24)
            Form {
                TextField(target.kind == .log || target.kind == .issue ? "内容" : "名称", text: $title, axis: .vertical).lineLimit(2...6)
                switch target.kind {
                case .project:
                    TextField("项目目标", text: $detail, axis: .vertical).lineLimit(3...6)
                    HStack {
                        Text("Git 仓库")
                        Spacer()
                        if checkingRepository { ProgressView().controlSize(.small) }
                        Button(repository.isEmpty ? "绑定本地仓库…" : "更换仓库…") { chooseRepository() }
                        if !repository.isEmpty { Button("解绑") { repository = "" } }
                    }
                    if !repository.isEmpty {
                        Text(repository).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        TextField("作者邮箱（留空使用 Git user.email）", text: $authorEmail)
                        Text("保存后每 5 分钟扫描所有本地分支的当天提交，展示为待确认工作。确认后加入记录与日报；同时读取未提交文件状态，不读取补丁正文，不联网。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("完成率按需要跟进的事项计算。归档会保留项目和记录。")
                        .font(.caption).foregroundStyle(.secondary)
                case .task:
                    Picker("状态", selection: $status) { ForEach(WorkStatus.allCases, id: \.self) { Text(WorkPilotStyle.title($0)).tag($0) } }
                    DisclosureGroup("更多（可不填）", isExpanded: $moreExpanded) {
                        TextField("补充说明", text: $detail, axis: .vertical).lineLimit(2...5)
                        projectPicker
                        DatePicker("计划日期", selection: $day, displayedComponents: .date)
                        Picker("优先级", selection: $priority) {
                            Text("高").tag(0); Text("普通").tag(1); Text("低").tag(2)
                        }
                    }
                case .log:
                    Picker("状态", selection: $logStatus) {
                        Text("记录").tag(nil as WorkStatus?)
                        ForEach(WorkStatus.allCases, id: \.self) { Text(WorkPilotStyle.title($0)).tag(Optional($0)) }
                    }
                    DisclosureGroup("更多（可不填）", isExpanded: $moreExpanded) {
                        TextField("补充结果", text: $result, axis: .vertical).lineLimit(2...5)
                        projectPicker
                        DatePicker("记录时间", selection: $day)
                    }
                case .issue:
                    Picker("状态", selection: $status) { ForEach(WorkStatus.allCases, id: \.self) { Text(WorkPilotStyle.title($0)).tag($0) } }
                    DisclosureGroup("更多（可不填）", isExpanded: $moreExpanded) {
                        TextField("补充背景", text: $detail, axis: .vertical).lineLimit(2...4)
                        TextField("解决方案", text: $solution, axis: .vertical).lineLimit(2...4)
                        TextField("下一步", text: $followUp, axis: .vertical).lineLimit(2...4)
                        projectPicker
                        Toggle("设置跟进日期", isOn: $hasDue)
                        if hasDue { DatePicker("跟进日期", selection: $due, displayedComponents: .date) }
                    }
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.ready || checkingRepository)
            }.padding(20)
        }.frame(width: 580, height: target.kind == .project ? 590 : target.kind == .task ? 480 : 400)
        .onAppear { load() }
        .alert("无法绑定仓库", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
            Button("好") { localError = nil }
        } message: { Text(localError ?? "") }
    }
    private var projectPicker: some View {
        Picker("所属项目", selection: $projectID) {
            Text("不选项目").tag(nil as UUID?)
            ForEach(model.data.projects.filter { !$0.archived || $0.id == projectID }) {
                Text($0.name).tag(Optional($0.id))
            }
        }
    }
    private func load() {
        guard !loaded else { return }; loaded = true
        switch target.kind {
        case .project:
            if let value = model.data.projects.first(where: { $0.id == target.entityID }) {
                title = value.name; detail = value.goal; repository = value.repositoryPath ?? ""; authorEmail = value.gitAuthorEmail ?? ""
            }
        case .task:
            if let value = model.data.tasks.first(where: { $0.id == target.entityID }) {
                title = value.title; detail = value.detail; projectID = value.projectID
                day = value.day; priority = value.priority; status = value.status
                moreExpanded = !value.detail.isEmpty
            }
        case .log:
            if let value = model.data.logs.first(where: { $0.id == target.entityID }) {
                title = value.action; result = value.result; projectID = value.projectID; day = value.date
                logStatus = value.followUpStatus
                moreExpanded = !value.result.isEmpty
            }
        case .issue:
            if let value = model.data.issues.first(where: { $0.id == target.entityID }) {
                title = value.title; detail = value.detail; solution = value.solution; followUp = value.followUp
                projectID = value.projectID; hasDue = value.due != nil; due = value.due ?? Date()
                status = value.resolvedAt != nil ? .done : (value.status ?? .todo)
                moreExpanded = !value.detail.isEmpty || !value.solution.isEmpty || !value.followUp.isEmpty || value.due != nil
            }
        }
    }
    private func save() {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.kind == .project, !repository.isEmpty,
           model.data.projects.contains(where: { $0.id != target.entityID && $0.repositoryPath == repository }) {
            localError = "这个仓库已绑定其他项目，请先解绑原项目。"; return
        }
        let saved = model.update { data in
            switch target.kind {
            case .project:
                var project = data.projects.first { $0.id == target.entityID } ?? WorkProject(name: title)
                project.name = title; project.goal = detail; project.repositoryPath = repository.isEmpty ? nil : repository
                project.gitAuthorEmail = authorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                data.projects.removeAll { $0.id == project.id }; data.projects.append(project)
            case .task:
                var task = data.tasks.first { $0.id == target.entityID } ?? WorkTask(title: title)
                task.title = title; task.detail = detail; task.projectID = projectID; task.day = day; task.priority = priority
                data.tasks.removeAll { $0.id == task.id }; data.tasks.append(task)
                data.setStatus(taskID: task.id, status: status)
                // Keep the derived log's editable result, but synchronize its task identity and project.
                for i in data.logs.indices where data.logs[i].taskID == task.id {
                    data.logs[i].action = title; data.logs[i].projectID = projectID
                }
            case .log:
                var log = data.logs.first { $0.id == target.entityID } ?? WorkLog(action: title)
                log.action = title; log.result = result; log.projectID = projectID; log.date = day
                data.logs.removeAll { $0.id == log.id }; data.logs.append(log)
                data.setRecordStatus(.log(log), status: logStatus)
            case .issue:
                var issue = data.issues.first { $0.id == target.entityID } ?? WorkIssue(title: title)
                issue.title = title; issue.detail = detail; issue.solution = solution; issue.followUp = followUp
                issue.projectID = projectID; issue.due = hasDue ? due : nil
                issue.status = status
                issue.resolvedAt = status == .done ? (issue.resolvedAt ?? Date()) : nil
                data.issues.removeAll { $0.id == issue.id }; data.issues.append(issue)
            }
        }
        if saved {
            if target.kind == .project, !repository.isEmpty { Task { await model.scanDiscoveries(day: Date(), quiet: true) } }
            dismiss()
        }
    }
    private func chooseRepository() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "选择要采集 Git 提交的本地项目目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        checkingRepository = true
        Task {
            defer { checkingRepository = false }
            do { repository = try await WorkPilotGit.repositoryRoot(url) }
            catch { localError = error.localizedDescription }
        }
    }
}

struct WorkPilotRulesView: View {
    @ObservedObject var model: WorkPilotModel
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [WorkRunningApp] = []
    @State private var bundleID = ""
    @State private var projectID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("自动计时设置").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("把常用应用关联到项目。比如把 IDEA 关联到“项目 A”，开启自动计时后，使用 IDEA 的时间就记到项目 A。若同一应用用于多个项目，直接用“开始专注”选择项目更准确。不需要计时就不用设置。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("运行中应用", selection: $bundleID) {
                    Text("请选择").tag("")
                    ForEach(apps) { Text($0.name).tag($0.id) }
                }
                Button { refreshApps() } label: { Image(systemName: "arrow.clockwise") }.help("刷新运行中应用")
            }
            DisclosureGroup("找不到应用？手动填写") {
                TextField("应用标识，例如 com.apple.dt.Xcode", text: $bundleID).textFieldStyle(.roundedBorder)
            }.font(.caption)
            Picker("归属项目", selection: $projectID) {
                Text("请选择项目").tag(nil as UUID?)
                ForEach(model.data.projects.filter { !$0.archived }) { Text($0.name).tag(Optional($0.id)) }
            }
            Button("关联应用与项目") { addRule() }.buttonStyle(.borderedProminent)
                .disabled(bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || projectID == nil)
            Divider()
            if model.data.rules.isEmpty {
                Text("还没有关联。也可以不设置，随时手动开始专注。").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.data.rules) { rule in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rule.appName).fontWeight(.medium)
                                Text(rule.bundleID).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(model.data.projectName(rule.projectID)).font(.callout)
                            Button { model.update { $0.rules.removeAll { $0.id == rule.id } } } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless).accessibilityLabel("删除 \(rule.appName) 的识别规则")
                        }.padding(12).background(Color.panel, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            Text("用时会自动保存在这台 Mac。空闲超过 2 分钟或休眠时暂停，重新打开 App 后需再次开启计时。这里只看当前应用，不读取窗口、网页或文件内容。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 610, height: 580).onAppear { refreshApps() }
    }
    private func refreshApps() {
        var unique: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier { unique[id] = app.localizedName ?? id }
        }
        apps = unique.map { WorkRunningApp(id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }
    private func addRule() {
        guard let id = projectID else { return }
        let bundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = apps.first { $0.id == bundle }?.name ?? bundle
        model.update { data in
            if !data.rules.contains(where: { $0.projectID == id && $0.bundleID == bundle }) {
                data.rules.append(WorkAppRule(projectID: id, bundleID: bundle, appName: name))
            }
        }
    }
}

private struct WorkRunningApp: Identifiable { let id: String; let name: String }
