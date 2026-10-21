import SwiftUI
import YukinoCore

@MainActor final class ProcessFinderModel: ObservableObject {
    @Published var query = ""
    @Published var mode = ProcessSearchMode.automatic
    @Published var processes: [LocalProcess] = []
    @Published var searching = false
    @Published var endingPID: Int32?
    @Published var hasSearched = false
    @Published var error: String?
    @Published var warning: String?
    @Published var notice: String?
    private let service = LocalProcessService()
    private var operation: Task<Void, Never>?
    var working: Bool { searching || endingPID != nil }

    func search() {
        guard !working else { return }
        searching = true; error = nil; warning = nil; notice = nil
        let input = query; let selection = mode
        operation = Task {
            defer { searching = false; operation = nil }
            do {
                let result = try await service.search(input, mode: selection)
                guard !Task.isCancelled else { return }
                processes = result.processes; warning = result.portWarning; hasSearched = true
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func terminate(_ process: LocalProcess) {
        guard !working else { return }
        endingPID = process.pid; error = nil; notice = nil
        let input = query; let selection = mode
        operation = Task {
            defer { endingPID = nil; operation = nil }
            do {
                let result = try await service.terminate(process)
                guard !Task.isCancelled else { return }
                switch result {
                case .exited: notice = "\(process.name)（PID \(process.pid)）已退出。"
                case .requested: notice = "已向 \(process.name)（PID \(process.pid)）发送结束请求，进程尚未退出，可稍后重新查找。"
                }
                do {
                    let updated = try await service.search(input, mode: selection)
                    guard !Task.isCancelled else { return }
                    processes = updated.processes; warning = updated.portWarning
                } catch { self.error = "结束操作已执行，但列表刷新失败：\(error.localizedDescription)" }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func cancel() { operation?.cancel() }
}

struct ProcessFinderView: View {
    @StateObject private var model = ProcessFinderModel()
    @EnvironmentObject private var state: AppState
    @State private var pending: LocalProcess?

    var body: some View {
        ToolPage(tool: .process) {
            Panel {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("查找方式", selection: $model.mode) {
                        Text("自动识别").tag(ProcessSearchMode.automatic)
                        Text("进程名称").tag(ProcessSearchMode.name)
                        Text("监听端口").tag(ProcessSearchMode.port)
                    }.pickerStyle(.segmented).frame(maxWidth: 360)
                    HStack(spacing: 12) {
                        TextField("输入名称或端口，例如 node、java、redis、3000", text: $model.query)
                            .textFieldStyle(.roundedBorder).onSubmit { model.search() }
                            .accessibilityLabel("进程名称或端口号")
                        Button { model.search() } label: {
                            HStack(spacing: 7) {
                                if model.searching { ProgressView().controlSize(.small) }
                                Text(model.searching ? "查找中…" : "查找")
                            }.frame(minWidth: 65)
                        }.buttonStyle(.borderedProminent)
                    }
                    Text("自动识别：纯数字按端口查找，其他内容按名称、可执行文件路径或启动命令匹配。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.disabled(model.working)
            }
            if let notice = model.notice { InlineMessage(message: notice) }
            if let error = model.error { InlineMessage(message: error, error: true) }
            if let warning = model.warning { InlineMessage(message: warning, error: true) }
            if model.hasSearched {
                HStack {
                    Text("找到 \(model.processes.count) 个进程").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Text("结束前会确认目标").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if model.processes.isEmpty {
                    Panel {
                        ContentUnavailableView("未找到匹配进程", systemImage: "magnifyingglass",
                                               description: Text("检查名称或端口后重试。端口查找只包含可见的本机 TCP 监听服务。"))
                            .frame(minHeight: 150)
                    }
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(model.processes) { process in processRow(process) }
                    }
                }
            } else if !model.searching {
                Panel {
                    ContentUnavailableView("查找占用端口的服务", systemImage: "cpu",
                                           description: Text("输入端口定位监听进程，或输入名称查找运行中的服务。"))
                        .frame(minHeight: 170)
                }
            }
            Text("仅展示 macOS 允许查看的进程。只能结束当前用户的普通进程；系统、其他用户和本应用只读。结束使用正常退出请求，受守护程序管理的服务可能自动重启。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onDisappear { model.cancel() }
        .alert("结束进程？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { process in
            Button("取消", role: .cancel) { pending = nil }
            Button("结束进程", role: .destructive) { model.terminate(process); pending = nil }
        } message: { process in
            Text("将结束 \(process.name)（PID \(String(process.pid))）。未保存的内容可能丢失。请确认这是你要停止的服务。")
        }
    }

    private func processRow(_ process: LocalProcess) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    SymbolTile(symbol: "cpu", size: 36)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(process.name).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                        Text("PID \(String(process.pid)) · \(process.owner) · UID \(String(process.uid))")
                            .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                    if model.endingPID == process.pid { ProgressView().controlSize(.small) }
                    Button("结束进程", role: .destructive) { pending = process }
                        .buttonStyle(.bordered).disabled(model.working || !process.canTerminate)
                        .help(process.canTerminate ? "发送正常退出请求" : "此进程仅供查看")
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("TCP 监听").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(process.listeningPorts.map { $0.isEmpty ? "无可见监听端口" : $0.map(String.init).joined(separator: " · ") } ?? "暂无法读取")
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
                Divider()
                Text(process.command).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).lineLimit(3).help(process.command)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("复制 PID") { state.copy(String(process.pid)) }
                    Button("复制命令") { state.copy(process.command) }
                }.controlSize(.small)
            }
        }
    }
}
