import AppKit
import SwiftUI
import UniformTypeIdentifiers
import YukinoCore

@MainActor
final class WorkPilotModel: ObservableObject {
    @Published private(set) var data = WorkPilotData()
    @Published var error: String?
    @Published private(set) var ready = false
    @Published private(set) var automatic = false
    @Published private(set) var manualProject: UUID?
    @Published private(set) var detectedProject: UUID?
    @Published private(set) var idle = false
    @Published private(set) var frontApp = ""
    @Published private(set) var frontBundle = ""
    @Published private(set) var scanningDiscoveries = false
    @Published private(set) var workingTrees: [UUID: WorkGitWorkingTree] = [:]
    @Published private(set) var discoveryStatus = "自动扫描 Git 提交和 Codex 工作会话"
    private let store = WorkPilotStore()
    private let codexScanner = WorkPilotCodexService()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastTick = Date()
    private var pauseReasons: Set<String> = []
    private var suspended: Bool { !pauseReasons.isEmpty }
    private var lastDiscoveryScan = Date.distantPast
    private var workspaceGeneration = 0
    var activeProject: UUID? { manualProject ?? (automatic ? detectedProject : nil) }
    var trackingLabel: String {
        if suspended { return "休眠中，计时暂停" }
        if idle { return "空闲中，计时暂停" }
        if let id = manualProject { return "专注于 \(data.projectName(id))" }
        if automatic, let id = detectedProject { return "自动识别：\(data.projectName(id))" }
        return automatic ? "\(frontApp.isEmpty ? "当前应用" : frontApp) 尚未匹配项目" : "计时未开启"
    }
    init() {
        do { data = try store.load(); ready = true }
        catch { self.error = "工作区读取失败，原文件已保留：\(error.localizedDescription)" }
        refreshFrontApp()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick(); self?.refreshFrontApp() }
        })
        for (name, reason) in [(NSWorkspace.willSleepNotification, "system"), (NSWorkspace.screensDidSleepNotification, "screen"), (NSWorkspace.sessionDidResignActiveNotification, "session")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.tick(); self?.pauseReasons.insert(reason) }
            })
        }
        for (name, reason) in [(NSWorkspace.didWakeNotification, "system"), (NSWorkspace.screensDidWakeNotification, "screen"), (NSWorkspace.sessionDidBecomeActiveNotification, "session")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lastTick = Date(); self?.pauseReasons.remove(reason); self?.refreshFrontApp() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        Task { await scanDiscoveries(day: Date(), quiet: true) }
    }

    @discardableResult
    func update(_ change: (inout WorkPilotData) -> Void) -> Bool {
        guard ready else { error = "请先恢复工作区，再保存更改。"; return false }
        var next = data
        change(&next)
        guard next != data else { return true }
        do { try store.save(next); data = next; refreshDetection(); return true }
        catch { self.error = "保存失败，更改未写入：\(error.localizedDescription)"; return false }
    }
    func setStatus(_ task: WorkTask, _ status: WorkStatus) {
        update { $0.setStatus(taskID: task.id, status: status) }
    }
    func changeStatus(_ entry: WorkRecordEntry, _ status: WorkStatus?) {
        update { $0.setRecordStatus(entry, status: status) }
    }
    func deleteRecord(_ entry: WorkRecordEntry) {
        update { data in
            switch entry {
            case .task(let task):
                data.tasks.removeAll { $0.id == task.id }
                data.logs.removeAll { $0.taskID == task.id }
            case .log(let log): data.logs.removeAll { $0.id == log.id }
            case .issue(let issue): data.issues.removeAll { $0.id == issue.id }
            }
        }
    }
    func setAutomatic(_ enabled: Bool) {
        tick(); automatic = enabled; refreshFrontApp(); lastTick = Date()
    }
    func focus(_ project: UUID?) {
        tick(); manualProject = project; lastTick = Date()
    }
    private func refreshFrontApp() {
        let app = NSWorkspace.shared.frontmostApplication
        frontApp = app?.localizedName ?? ""
        frontBundle = app?.bundleIdentifier ?? ""
        refreshDetection()
    }
    private func refreshDetection() { detectedProject = data.detectedProject(bundleID: frontBundle) }
    private func tick() {
        let now = Date(), elapsed = now.timeIntervalSince(lastTick)
        if ready, !suspended, now.timeIntervalSince(lastDiscoveryScan) >= 300, !scanningDiscoveries {
            Task { await scanDiscoveries(day: Date(), quiet: true) }
        }
        let wasIdle = idle
        idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null) >= 120
        defer { lastTick = now }
        guard ready, !suspended, !idle, !wasIdle, elapsed > 0, elapsed <= 30, let id = activeProject,
              data.projects.contains(where: { $0.id == id && !$0.archived }) else { return }
        let start = lastTick, auto = manualProject == nil
        if !update({ $0.recordTime(projectID: id, start: start, end: now, automatic: auto) }) {
            manualProject = nil; automatic = false
        }
    }
    func archive(_ project: WorkProject) {
        if manualProject == project.id { focus(nil) }
        update { data in
            guard let i = data.projects.firstIndex(where: { $0.id == project.id }) else { return }
            data.projects[i].archived.toggle()
        }
    }
    func deleteTask(_ task: WorkTask) {
        update { data in
            data.tasks.removeAll { $0.id == task.id }
            // Keep actual work history, detached from the deleted task.
            for i in data.logs.indices where data.logs[i].taskID == task.id { data.logs[i].taskID = nil }
        }
    }
    func saveReport(day: Date, markdown: String) -> Bool {
        update { data in
            let day = Calendar.current.startOfDay(for: day)
            data.reports.removeAll { $0.day == day }
            data.reports.append(WorkReportDraft(day: day, markdown: markdown))
        }
    }
    func sendToCodex(material: String, day: Date) async -> Bool {
        guard ready else { return false }
        do {
            let prompt = WorkPilotCodexHandoff.prompt(material: material, day: day)
            let url = try WorkPilotCodexHandoff.url(prompt: prompt)
            guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
                throw ToolError.invalid("没有找到支持此链接的 Codex Desktop，请先安装并打开 Codex Desktop。")
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            return true
        } catch { self.error = "打开 Codex 失败：\(error.localizedDescription)"; return false }
    }
    func exportBackup() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "WorkPilot-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(data).write(to: url, options: .atomic)
        } catch { self.error = "备份导出失败：\(error.localizedDescription)" }
    }
    func importBackup() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 20_000_000 else { throw ToolError.invalid("备份超过 20 MB") }
            let imported = try WorkPilotStore.decode(Data(contentsOf: url))
            let alert = NSAlert(); alert.messageText = "用备份替换 WorkPilot 工作区？"
            alert.informativeText = "将导入 \(imported.projects.count) 个项目、\(imported.tasks.count) 个任务和 \(imported.logs.count) 条记录。当前工作区会先保存为恢复副本。"
            alert.addButton(withTitle: "替换工作区"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            manualProject = nil; automatic = false
            workspaceGeneration += 1
            if FileManager.default.fileExists(atPath: store.url.path) {
                let recovery = store.url.deletingLastPathComponent().appendingPathComponent("workspace-before-import-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: store.url, to: recovery)
                // Move a corrupt primary aside too, so save never overwrites unreadable data.
                if !ready { try FileManager.default.removeItem(at: store.url) }
            }
            try store.save(imported); data = imported; workingTrees = [:]; ready = true; refreshDetection(); lastTick = Date()
        } catch { self.error = "导入失败：\(error.localizedDescription)" }
    }
    func revealStorage() {
        NSWorkspace.shared.selectFile(store.url.path, inFileViewerRootedAtPath: store.url.deletingLastPathComponent().path)
    }
    func scanDiscoveries(day: Date, quiet: Bool = false) async {
        guard ready, !scanningDiscoveries else { return }
        let projects = data.projects.filter { !$0.archived && $0.repositoryPath != nil }
        lastDiscoveryScan = Date()
        scanningDiscoveries = true
        defer { scanningDiscoveries = false }
        let generation = workspaceGeneration
        var count = 0, failures: [String] = []
        for project in projects {
            guard let path = project.repositoryPath else { continue }
            do {
                let commits = try await WorkPilotGit.scan(repository: URL(fileURLWithPath: path), day: day, authorEmail: project.gitAuthorEmail)
                guard generation == workspaceGeneration else { return }
                guard data.projects.contains(where: { $0.id == project.id && $0.repositoryPath == path && $0.gitAuthorEmail == project.gitAuthorEmail && !$0.archived }) else { continue }
                let workingTree = try await WorkPilotGit.workingTree(repository: URL(fileURLWithPath: path))
                guard generation == workspaceGeneration else { return }
                guard data.projects.contains(where: { $0.id == project.id && $0.repositoryPath == path && $0.gitAuthorEmail == project.gitAuthorEmail && !$0.archived }) else { continue }
                var added = 0
                if update({ added = $0.discoverCommits(commits, projectID: project.id, repository: path) }) { count += added }
                else { failures.append("\(project.name)：工作记录保存失败") }
                workingTrees[project.id] = workingTree
            } catch { workingTrees.removeValue(forKey: project.id); failures.append("\(project.name)：\(error.localizedDescription)") }
        }
        var codexCount = 0
        let configured = UserDefaults.standard.string(forKey: "codexDataPath") ?? ""
        let path = NSString(string: configured.isEmpty ? ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "~/.codex" : configured).expandingTildeInPath
        do {
            let scan = try await codexScanner.scan(root: URL(fileURLWithPath: path), day: day)
            guard generation == workspaceGeneration else { return }
            if !update({ codexCount = $0.discoverCodexActivities(scan.activities) }) { failures.append("Codex：会话记录保存失败") }
            if scan.unreadableFiles > 0 { failures.append("Codex：\(scan.unreadableFiles) 个文件无法读取") }
            if scan.limited { failures.append("Codex：达到本次读取上限，下次扫描继续") }
        } catch { failures.append("Codex：\(error.localizedDescription)") }
        discoveryStatus = "新增 Git \(count) 条 · Codex \(codexCount) 条 · \(Date().formatted(date: .omitted, time: .shortened))"
        if !failures.isEmpty {
            discoveryStatus += "；" + failures.joined(separator: "；")
            if !quiet { error = failures.joined(separator: "\n") }
        }
    }
}
