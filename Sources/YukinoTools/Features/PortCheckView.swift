import SwiftUI
import YukinoCore

struct PortHistory: Codable, Identifiable {
    var id: UUID = UUID()
    let host: String
    let port: String
    let connected: Bool
    let date: Date
}

@MainActor final class PortViewModel: ObservableObject {
    @Published var host = "127.0.0.1"
    @Published var port = "5432"
    @Published var checking = false
    @Published var result: PortResult?
    @Published var error: String?
    @Published var history: [PortHistory] = []
    private let defaults = UserDefaults.standard
    init() {
        if let data = defaults.data(forKey: "portHistory"), let history = try? JSONDecoder().decode([PortHistory].self, from: data) { self.history = history }
    }
    func check() async {
        guard !checking else { return }
        checking = true; result = nil; error = nil
        defer { checking = false }
        do {
            let result = try await PortService.check(host: host, port: port, timeout: Double(defaults.integer(forKey: "networkTimeout") == 0 ? 5 : defaults.integer(forKey: "networkTimeout")))
            self.result = result
            let cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines)
            history.removeAll { $0.host == cleaned && $0.port == port }
            history.insert(PortHistory(host: cleaned, port: port, connected: result.connected, date: Date()), at: 0)
            history = Array(history.prefix(10))
            defaults.set(try? JSONEncoder().encode(history), forKey: "portHistory")
        } catch { self.error = error.localizedDescription }
    }
}

struct PortCheckView: View {
    @StateObject private var model = PortViewModel()
    var body: some View {
        ToolPage(tool: .port) {
            Panel {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .bottom, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Host").font(.system(size: 12, weight: .medium))
                            TextField("127.0.0.1 or example.com", text: $model.host).textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Port").font(.system(size: 12, weight: .medium))
                            TextField("5432", text: $model.port).textFieldStyle(.roundedBorder)
                        }.frame(width: 120)
                        Button { Task { await model.check() } } label: {
                            HStack(spacing: 8) {
                                if model.checking { ProgressView().controlSize(.small) }
                                Text(model.checking ? "Checking…" : "Check connection")
                            }
                        }.buttonStyle(.borderedProminent)
                    }.disabled(model.checking)
                    Divider()
                    if let result = model.result {
                        HStack(spacing: 14) {
                            Image(systemName: result.connected ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 28)).foregroundStyle(result.connected ? .green : .orange)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(result.connected ? "Connected" : "Connection failed").font(.system(size: 17, weight: .semibold))
                                Text(result.message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Text(String(format: "%.1f ms", result.latency)).font(.system(size: 20, weight: .medium, design: .rounded))
                        }.padding(.vertical, 12)
                    } else if let error = model.error {
                        InlineMessage(message: error, error: true)
                    } else {
                        Label("Enter a host and port to test a TCP connection.", systemImage: "network")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recent checks").font(.system(size: 17, weight: .semibold))
                    if model.history.isEmpty {
                        Text("Your checked endpoints will appear here.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    ForEach(model.history) { item in
                        Button { model.host = item.host; model.port = item.port; model.result = nil; model.error = nil } label: {
                            HStack {
                                Circle().fill(item.connected ? Color.green : Color.orange).frame(width: 6, height: 6)
                                Text("\(item.host):\(item.port)").font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Text(item.date, style: .relative).font(.system(size: 11)).foregroundStyle(.secondary)
                                Image(systemName: "arrow.up.left").font(.system(size: 11)).foregroundStyle(.secondary)
                            }.contentShape(Rectangle()).padding(.vertical, 8)
                        }.buttonStyle(.plain).disabled(model.checking)
                    }
                }
            }
        }
    }
}
