import SwiftUI
import YukinoCore

@MainActor final class CronViewModel: ObservableObject {
    @Published var expression = "0 9 * * MON-FRI"
    @Published var dialect = CronDialect.standard
    @Published var timeZoneID = TimeZone.current.identifier
    @Published var start = Date()
    @Published var schedule: CronSchedule?
    @Published var dates = [Date]()
    @Published var working = false
    @Published var error: String?
    private var operation: Task<Void, Never>?

    func refresh() {
        operation?.cancel()
        schedule = nil; dates = []; error = nil; working = true
        let input = expression, dialect = dialect, zoneID = timeZoneID, after = start
        operation = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                guard let zone = TimeZone(identifier: zoneID) else { throw ToolError.invalid("无效的时区，请输入 IANA 标识，例如 Asia/Shanghai。") }
                let worker = Task.detached(priority: .userInitiated) {
                    let parsed = try CronSchedule(input, dialect: dialect)
                    return (parsed, try parsed.nextDates(after: after, timeZone: zone))
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                schedule = result.0; dates = result.1; working = false
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription; working = false
            }
        }
    }
    func cancel() { operation?.cancel(); working = false }
    func example(_ value: String, dialect: CronDialect) { self.dialect = dialect; expression = value }
    func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        formatter.dateFormat = "yyyy-MM-dd EEEE HH:mm:ss XXXXX"
        return formatter.string(from: date)
    }
}

struct CronView: View {
    @StateObject private var model = CronViewModel()
    @EnvironmentObject private var state: AppState
    var body: some View {
        ToolPage(tool: .cron) {
            Panel {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("语法", selection: $model.dialect) {
                        ForEach(CronDialect.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    HStack {
                        TextField(model.dialect == .standard ? "分 时 日 月 星期" : "秒 分 时 日 月 星期 [年]", text: $model.expression)
                            .font(.system(size: 17, design: .monospaced)).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Cron 表达式")
                        Button { state.copy(model.expression) } label: { Image(systemName: "doc.on.doc") }.help("复制表达式")
                        Menu("示例") {
                            Button("标准 · 每 5 分钟") { model.example("*/5 * * * *", dialect: .standard) }
                            Button("标准 · 周一至周五 09:00") { model.example("0 9 * * MON-FRI", dialect: .standard) }
                            Button("标准 · 每月 1 日或每周一") { model.example("0 9 1 * MON", dialect: .standard) }
                            Divider()
                            Button("Quartz · 每 10 秒") { model.example("0/10 * * * * ?", dialect: .quartz) }
                            Button("Quartz · 每月最后一天") { model.example("0 0 9 L * ?", dialect: .quartz) }
                            Button("Quartz · 每月最后一个工作日") { model.example("0 0 9 LW * ?", dialect: .quartz) }
                            Button("Quartz · 每月第三个周五") { model.example("0 0 9 ? * FRI#3", dialect: .quartz) }
                        }.fixedSize()
                    }
                    HStack {
                        TextField("IANA 时区", text: $model.timeZoneID).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("预览时区")
                        Menu("常用时区") {
                            ForEach(Array(Set([TimeZone.current.identifier, "Asia/Shanghai", "UTC", "America/New_York", "Europe/London"])).sorted(), id: \.self) { id in
                                Button(id) { model.timeZoneID = id }
                            }
                        }.fixedSize()
                    }
                    HStack {
                        DatePicker("预览起点", selection: $model.start, in: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 4102444799), displayedComponents: [.date, .hourAndMinute])
                            .environment(\.timeZone, TimeZone(identifier: model.timeZoneID) ?? .current)
                        Button("当前时间") { model.start = Date() }
                    }
                    Text(model.dialect == .standard ? "分 时 日 月 星期；星期 0 / 7 为周日。支持 * , - / 和英文月份、星期名。" : "秒 分 时 日 月 星期 [年]；星期 1 为周日。支持 ?、L、L-n、W、LW、nL、n#k；日和星期须恰好有一个为 ?。年份 1970–2099。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if model.working { ProgressView("正在解析并计算…") }
            if let error = model.error { InlineMessage(message: error, error: true) }
            if let schedule = model.schedule {
                Panel {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("表达式说明").font(.headline)
                        Text(schedule.explanation).font(.system(size: 13)).textSelection(.enabled)
                        ForEach(schedule.fields, id: \.name) { field in
                            HStack(alignment: .top, spacing: 16) {
                                Text(field.name).frame(width: 36, alignment: .leading).foregroundStyle(.secondary)
                                Text(field.expression).font(.system(size: 12, design: .monospaced)).frame(width: 110, alignment: .leading)
                                Text(field.explanation).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(size: 12)).textSelection(.enabled)
                        }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("未来 10 次执行时间").font(.headline)
                            Spacer()
                            Button("复制列表") { state.copy(model.dates.map(model.format).joined(separator: "\n")) }.disabled(model.dates.isEmpty)
                        }
                        Text("\(model.timeZoneID) · 严格晚于预览起点").font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(Array(model.dates.enumerated()), id: \.offset) { index, date in
                            HStack(spacing: 16) {
                                Text(String(format: "%02d", index + 1)).foregroundStyle(.tertiary)
                                Text(model.format(date)).textSelection(.enabled)
                            }.font(.system(size: 12, design: .monospaced))
                        }
                        if model.dates.count < 10 {
                            InlineMessage(message: model.dates.isEmpty ? "从起点到 2099 年末没有匹配时间，请检查日期组合或年份。" : "到 2099 年末仅有 \(model.dates.count) 次匹配。", error: true)
                        }
                    }
                }
            }
            Text("仅在本机解释与预览，不创建系统任务。预览跳过夏令时不存在的时间，并列出重复时间的两个实际时刻；实际调度器的补偿或重复执行策略可能不同。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onAppear { model.refresh() }
        .onChange(of: model.expression) { _, _ in model.refresh() }
        .onChange(of: model.dialect) { _, _ in model.refresh() }
        .onChange(of: model.timeZoneID) { _, _ in model.refresh() }
        .onChange(of: model.start) { _, _ in model.refresh() }
        .onDisappear { model.cancel() }
    }
}
