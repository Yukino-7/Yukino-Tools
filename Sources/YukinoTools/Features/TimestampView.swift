import SwiftUI
import YukinoCore

@MainActor final class TimestampViewModel: ObservableObject {
    @Published var unit: TimestampService.Unit = .seconds
    @Published var utc = false
    @Published var timestampInput = TimestampService.timestamp(from: Date(), unit: .seconds)
    @Published var dateInput = TimestampService.formatter(utc: false).string(from: Date())
    @Published var dateOutput = ""
    @Published var timestampOutput = ""
    @Published var dateError: String?
    @Published var timestampError: String?
    func convertTimestamp() {
        do {
            let date = try TimestampService.date(from: timestampInput, unit: unit)
            dateOutput = TimestampService.formatter(utc: utc).string(from: date)
            dateError = nil
        } catch { dateOutput = ""; dateError = error.localizedDescription }
    }
    func convertDate() {
        do {
            let date = try TimestampService.parse(dateInput, utc: utc)
            timestampOutput = TimestampService.timestamp(from: date, unit: unit)
            timestampError = nil
        } catch { timestampOutput = ""; timestampError = error.localizedDescription }
    }
}

struct TimestampView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = TimestampViewModel()
    var body: some View {
        ToolPage(tool: .timestamp) {
            Panel {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("CURRENT UNIX TIMESTAMP").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                            Text(TimestampService.timestamp(from: context.date, unit: model.unit))
                                .font(.system(size: 32, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            Text(context.date.formatted(date: .complete, time: .standard)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { state.copy(TimestampService.timestamp(from: context.date, unit: model.unit)) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                }
            }
            HStack {
                Picker("Unit", selection: $model.unit) {
                    ForEach(TimestampService.Unit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 230)
                Spacer()
                Picker("Time zone", selection: $model.utc) {
                    Text("Local time").tag(false)
                    Text("UTC").tag(true)
                }.pickerStyle(.segmented).frame(width: 190)
            }
            HStack(alignment: .top, spacing: 20) {
                Panel {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Timestamp → Date", systemImage: "calendar").font(.system(size: 16, weight: .semibold))
                        TextField("Unix timestamp", text: $model.timestampInput).textFieldStyle(.roundedBorder).onSubmit { model.convertTimestamp() }
                        Button("Convert to date") { model.convertTimestamp() }.buttonStyle(.borderedProminent)
                        Divider()
                        Text(model.dateOutput.isEmpty ? "Your date will appear here" : model.dateOutput)
                            .font(.system(size: 14, design: .monospaced)).foregroundStyle(model.dateOutput.isEmpty ? .secondary : .primary).textSelection(.enabled)
                        Text(model.utc ? "UTC" : TimeZone.current.identifier).font(.system(size: 10)).foregroundStyle(.secondary)
                        if let error = model.dateError { InlineMessage(message: error, error: true) }
                        Button("Copy date") { state.copy(model.dateOutput) }.disabled(model.dateOutput.isEmpty)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Panel {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Date → Timestamp", systemImage: "clock").font(.system(size: 16, weight: .semibold))
                        TextField("yyyy-MM-dd HH:mm:ss", text: $model.dateInput).textFieldStyle(.roundedBorder).onSubmit { model.convertDate() }
                        Button("Convert to timestamp") { model.convertDate() }.buttonStyle(.borderedProminent)
                        Divider()
                        Text(model.timestampOutput.isEmpty ? "Your timestamp will appear here" : model.timestampOutput)
                            .font(.system(size: 14, design: .monospaced)).foregroundStyle(model.timestampOutput.isEmpty ? .secondary : .primary).textSelection(.enabled)
                        Text(model.unit.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
                        if let error = model.timestampError { InlineMessage(message: error, error: true) }
                        Button("Copy timestamp") { state.copy(model.timestampOutput) }.disabled(model.timestampOutput.isEmpty)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onChange(of: model.unit) { _, _ in model.dateOutput = ""; model.timestampOutput = "" }
        .onChange(of: model.utc) { _, _ in model.convertTimestamp(); model.convertDate() }
    }
}
