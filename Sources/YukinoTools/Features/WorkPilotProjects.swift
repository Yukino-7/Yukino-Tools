import SwiftUI
import YukinoCore

struct WorkProjectDetailView: View {
    @ObservedObject var model: WorkPilotModel
    let projectID: UUID
    let day: Date
    let close: () -> Void
    let edit: () -> Void
    let showRecords: () -> Void
    private var project: WorkProject? { model.data.projects.first { $0.id == projectID } }
    private var items: [WorkRecordEntry] { model.data.allRecords.filter { $0.projectID == projectID } }
    var body: some View {
        if let project {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "folder").font(.title2).foregroundStyle(.secondary)
                    Text(project.name).font(.headline).lineLimit(2)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭项目详情")
                }.padding(20)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if !project.goal.isEmpty { Text(project.goal).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                        VStack(alignment: .leading, spacing: 10) {
                            let actions = items.filter { $0.status != nil }
                            HStack {
                                Text("\(actions.filter { $0.status == .done }.count)/\(actions.count) 项完成").font(.caption)
                                Spacer()
                                Text(model.data.progress(for: projectID), format: .percent.precision(.fractionLength(0))).font(.caption).foregroundStyle(.secondary)
                            }
                            WorkProgressBar(value: model.data.progress(for: projectID))
                        }.help("进度统计待跟进、进行中、阻塞及已完成事项，普通记录不计入完成率。")
                        VStack(alignment: .leading, spacing: 10) {
                            Text("最近进展").font(.system(size: 12, weight: .semibold))
                            let recent = items.filter { !$0.isPending }.sorted { $0.date > $1.date }
                            if recent.isEmpty { Text("还没有记录").font(.caption).foregroundStyle(.secondary) }
                            ForEach(Array(recent.prefix(5))) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: WorkPilotStyle.symbol(entry.status)).foregroundStyle(WorkPilotStyle.color(entry.status))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(entry.title).font(.system(size: 12)).lineLimit(3)
                                        Text(entry.date, format: .dateTime.month().day().hour().minute()).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("待跟进").font(.system(size: 12, weight: .semibold))
                            let pending = items.filter(\.isPending).sorted { $0.date < $1.date }
                            if pending.isEmpty { Text("没有待跟进事项").font(.caption).foregroundStyle(.secondary) }
                            ForEach(Array(pending.prefix(6))) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Button { model.changeStatus(entry, .done) } label: {
                                        Image(systemName: "circle").foregroundStyle(WorkPilotStyle.color(entry.status))
                                    }.buttonStyle(.plain).accessibilityLabel("标记完成：\(entry.title)")
                                    Text(entry.title).font(.system(size: 12)).lineLimit(3)
                                    if entry.status == .blocked { WorkStatusBadge(status: .blocked) }
                                }
                            }
                        }
                        if let repository = project.repositoryPath {
                            Label(URL(fileURLWithPath: repository).lastPathComponent, systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.caption).foregroundStyle(.secondary).help(repository)
                        }
                        HStack { Button("查看全部记录", action: showRecords); Spacer() }
                    }.padding(20)
                }
                Divider()
                Button(action: edit) { Label("管理项目", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity) }
                    .padding(16)
            }.frame(maxHeight: .infinity).background(Color.canvas)
        } else {
            ContentUnavailableView("项目暂不可用", systemImage: "folder")
        }
    }
}

struct WorkProjectManagerView: View {
    @ObservedObject var model: WorkPilotModel
    @Environment(\.dismiss) private var dismiss
    @State private var showArchived = false
    @State private var editor: WorkEditorTarget?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("管理项目").font(.title2.weight(.semibold))
                Spacer()
                Button("新建项目") { editor = WorkEditorTarget(kind: .project) }.buttonStyle(.borderedProminent)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Toggle("显示已归档项目", isOn: $showArchived).toggleStyle(.checkbox).font(.caption)
            ScrollView {
                VStack(spacing: 12) {
                    let projects = model.data.projects.filter { showArchived || !$0.archived }
                    if projects.isEmpty { ContentUnavailableView("还没有项目", systemImage: "folder.badge.plus", description: Text("可选创建项目，关联记录和本地仓库。")) }
                    ForEach(projects) { project in
                        WorkCard {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: project.archived ? "archivebox" : "folder").font(.title2).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(project.name).font(.headline)
                                    if !project.goal.isEmpty { Text(project.goal).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    if let path = project.repositoryPath {
                                        Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if project.archived { Text("已归档").font(.caption).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button("编辑") { editor = WorkEditorTarget(kind: .project, entityID: project.id) }
                                Menu {
                                    Button(project.archived ? "恢复项目" : "归档项目") { model.archive(project) }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                            }
                        }
                    }
                }
            }
        }.padding(24).frame(width: 640, height: 520)
            .sheet(item: $editor) { WorkPilotEditor(model: model, target: $0, defaultDay: Date(), defaultProject: nil) }
    }
}
