import SwiftUI
import YukinoCore

@MainActor final class JWTViewModel: ObservableObject {
    @Published var input = ""
    @Published var document: JWTDocument?
    @Published var error: String?
    func decode() {
        document = nil; error = nil
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { document = try JWTService.decode(input) }
        catch { self.error = error.localizedDescription }
    }
}

struct JWTView: View {
    @StateObject private var model = JWTViewModel()
    @EnvironmentObject private var state: AppState
    @State private var utc = false
    var body: some View {
        ToolPage(tool: .jwt) {
            HStack {
                Button("载入示例") { model.input = JWTService.example }
                Button("清空") { model.input = "" }
                Spacer()
                Picker("时间显示", selection: $utc) {
                    Text("本地时间").tag(false)
                    Text("UTC").tag(true)
                }.pickerStyle(.segmented).frame(width: 190)
            }
            EditorPanel(title: "JWT · 支持 Bearer 前缀", text: $model.input).frame(height: 145)
            if let error = model.error { InlineMessage(message: error, error: true) }
            if let document = model.document {
                Panel {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("签名未验证", systemImage: "lock.trianglebadge.exclamationmark").font(.headline).foregroundStyle(.orange)
                        Text("算法：\(document.algorithm) · 签名：\(document.signatureBytes) bytes")
                            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        Text("解码成功不代表令牌可信。此工具不验证签名、签发者或受众，时间声明也来自未验证的 Payload。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        ForEach(document.warnings, id: \.self) { warning in InlineMessage(message: warning, error: true) }
                    }
                }
                HStack(alignment: .top, spacing: 18) {
                    jsonPanel(title: "HEADER", value: document.header)
                    jsonPanel(title: "PAYLOAD", value: document.payload)
                }
                Panel {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 14) {
                            Text("时间声明").font(.headline)
                            let status = document.timeState(at: context.date)
                            Text(status.title).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(status == .expired || status == .notYetValid || status == .invalidTimeClaims ? Color.orange : Color.primary)
                            if document.dateClaims.isEmpty {
                                Text("未找到可解析的 iat / nbf / exp 数值声明。").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            ForEach(document.dateClaims) { claim in
                                HStack(alignment: .top, spacing: 14) {
                                    Text(claim.name).frame(width: 36, alignment: .leading).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(format(claim.date)).textSelection(.enabled)
                                        Text("Unix 秒：\(String(format: "%.3f", claim.date.timeIntervalSince1970))").foregroundStyle(.secondary)
                                    }
                                }.font(.system(size: 12, design: .monospaced))
                            }
                            if let expiration = document.expiration {
                                let remaining = expiration.timeIntervalSince(context.date)
                                Text(remaining > 0 ? "距离声明过期还有 \(duration(remaining))" : "距离声明过期已过去 \(duration(-remaining))")
                                    .font(.system(size: 12)).monospacedDigit()
                            }
                            Text(utc ? "UTC" : TimeZone.current.identifier).font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if model.error == nil {
                ContentUnavailableView("粘贴 JWT 查看内容", systemImage: "key.horizontal", description: Text("本机解析 Header、Payload 与有效期；支持三段式 JWT，不支持 JWE 解密。"))
            }
            Text("输入只在当前页面内存中处理，不上传、不写入历史或设置。iat 是签发时间，不作为生效边界；时间检查不添加时钟容差。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.onChange(of: model.input) { _, _ in model.decode() }
    }
    private func jsonPanel(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorPanel(title: title, text: .constant(value), editable: false, json: true).frame(height: 250)
            Button("复制 \(title)") { state.copy(value) }
        }.frame(maxWidth: .infinity)
    }
    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = utc ? TimeZone(secondsFromGMT: 0)! : .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS XXXXX"
        return formatter.string(from: date)
    }
    private func duration(_ seconds: Double) -> String {
        let value = Int(seconds.rounded(.up))
        return "\(value / 86400) 天 \((value % 86400) / 3600) 时 \((value % 3600) / 60) 分 \(value % 60) 秒"
    }
}
