import SwiftUI
import YukinoCore

struct WorkCodexDiscoveryRow: View {
    @ObservedObject var model: WorkPilotModel
    let item: WorkCodexDiscovery
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "terminal").foregroundStyle(.secondary).font(.title3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.activity.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    HStack {
                        Text(item.activity.date, style: .time)
                        Text(item.projectID.map { model.data.projectName($0) } ?? "未匹配项目")
                        if item.state == .ignored { Text("已忽略") }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("查看会话内容", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("事项").font(.caption.weight(.medium))
                    Text(item.activity.request).font(.caption).textSelection(.enabled)
                    Text("最终答复（未经独立验证）").font(.caption.weight(.medium))
                    Text(item.activity.response).font(.caption).textSelection(.enabled)
                    if item.activity.truncated { Text("长内容已截取，完整记录可打开原会话查看。").font(.caption).foregroundStyle(.secondary) }
                    Text(item.activity.directory).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Picker("归属项目", selection: Binding(get: { item.projectID }, set: { projectID in
                        model.update { data in
                            if let i = data.codexDiscoveries.firstIndex(where: { $0.id == item.id }) { data.codexDiscoveries[i].projectID = projectID }
                        }
                    })) {
                        Text("暂不选择").tag(nil as UUID?)
                        ForEach(model.data.projects.filter { !$0.archived || $0.id == item.projectID }) { Text($0.name).tag(Optional($0.id)) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.font(.caption)
            HStack {
                if let url = sessionURL { Link("打开会话", destination: url).font(.caption) }
                Spacer()
                Button(item.state == .ignored ? "恢复" : "忽略") { model.update { $0.setCodexDiscovery(item.id, state: item.state == .ignored ? .pending : .ignored) } }
                Button("加入记录") { model.update { $0.setCodexDiscovery(item.id, state: .accepted) } }
            }.controlSize(.small)
            Divider()
        }.padding(.vertical, 5)
    }
    private var sessionURL: URL? {
        var url = URLComponents(); url.scheme = "codex"; url.host = "threads"; url.path = "/\(item.activity.sessionID)"
        return url.url
    }
}
