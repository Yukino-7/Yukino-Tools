import SwiftUI
import AppKit
import YukinoCore

@MainActor final class CurlViewModel: ObservableObject {
    @Published var sourceShell = CurlShell.bash
    @Published var targetShell = CurlShell.bash
    @Published var multiline = true
    @Published var cmdStyle = CurlCMDStyle.native
    @Published var checking = false
    @Published var inputCommand = ""
    @Published var command = ""
    @Published var warnings = [String]()
    @Published var error: String?
    @Published var plan: CurlCommandPlan?
    @Published private(set) var favorites = [CurlFavorite]()
    @Published private(set) var selectedID: UUID?
    @Published private(set) var favoritesError: String?
    @Published var notice: String?
    private let favoritesStore = CurlFavoritesStore()
    private var importedPlan: CurlCommandPlan?
    private var importOperation: Task<Void, Never>?
    private var revision = 0

    init() { reloadFavorites() }
    var favoritesStorePath: String { favoritesStore.fileURL.path }
    var selected: CurlFavorite? { favorites.first { $0.id == selectedID } }
    var modified: Bool { selected.map { $0.command != inputCommand || $0.sourceShell != sourceShell } ?? false }
    var hasUnsavedInput: Bool { !inputCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (selected == nil || modified) }
    var canSave: Bool { favoritesError == nil && !inputCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && inputCommand.utf8.count <= 262_144 && !inputCommand.contains("\0") }

    func refresh() {
        guard let importedPlan else { return }
        command = ""; warnings = []; error = nil; plan = importedPlan
        do {
            let rendered = try CurlShellService.render(importedPlan, shell: targetShell, multiline: multiline, cmdStyle: cmdStyle, prettyJSON: true)
            command = rendered.text; warnings = importedPlan.warnings + rendered.warnings
        } catch { self.error = error.localizedDescription }
    }
    func scheduleImport() {
        cancelImport()
        importedPlan = nil; command = ""; warnings = []; plan = nil; error = nil
        guard !inputCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let source = inputCommand, shell = sourceShell, operationRevision = revision
        checking = true
        importOperation = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let worker = Task.detached(priority: .userInitiated) { try CurlCommandParser.parse(source, shell: shell) }
                let parsed = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard revision == operationRevision else { return }
                importedPlan = parsed; checking = false; refresh()
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, revision == operationRevision else { return }
                checking = false; self.error = error.localizedDescription
            }
        }
    }
    func cancelImport() { revision += 1; importOperation?.cancel(); importOperation = nil; checking = false }
    func clear() {
        cancelImport()
        selectedID = nil; inputCommand = ""; importedPlan = nil; command = ""; warnings = []; error = nil; plan = nil; notice = nil
    }
    func example(_ json: Bool) {
        selectedID = nil; sourceShell = .bash
        inputCommand = json
            ? "curl 'https://example.com/api/items' \\\n  -H 'Content-Type: application/json' \\\n  --data-raw '{\"name\":\"Yukino\",\"enabled\":true}'"
            : "curl 'https://example.com/api/items?page=1' \\\n  -H 'Accept: application/json'"
        notice = nil; scheduleImport()
    }
    func load(_ favorite: CurlFavorite) {
        selectedID = favorite.id; inputCommand = favorite.command; sourceShell = favorite.sourceShell
        notice = nil; scheduleImport()
    }
    func reloadFavorites() {
        do {
            favorites = try favoritesStore.load(); favoritesError = nil
            if let selectedID, !favorites.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        } catch { favoritesError = "收藏读取失败，原文件已保留：\(error.localizedDescription)" }
    }
    @discardableResult func saveFavorite(name: String, asNew: Bool) -> Bool {
        guard canSave else { return false }
        var updated = favorites
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: UUID
        if !asNew, let index = updated.firstIndex(where: { $0.id == selectedID }) {
            updated[index].name = name; updated[index].command = inputCommand
            updated[index].sourceShell = sourceShell; updated[index].updatedAt = Date()
            id = updated[index].id
            let item = updated.remove(at: index); updated.insert(item, at: 0)
        } else {
            let item = CurlFavorite(name: name, command: inputCommand, sourceShell: sourceShell)
            id = item.id; updated.insert(item, at: 0)
        }
        do {
            try favoritesStore.save(updated); favorites = updated; selectedID = id
            notice = asNew ? "已加入收藏" : "收藏已更新"
            return true
        } catch { notice = "收藏保存失败：\(error.localizedDescription)"; return false }
    }
    @discardableResult func renameFavorite(_ name: String) -> Bool {
        guard let index = favorites.firstIndex(where: { $0.id == selectedID }) else { return false }
        var updated = favorites
        updated[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines); updated[index].updatedAt = Date()
        do { try favoritesStore.save(updated); favorites = updated; notice = "收藏名称已更新"; return true }
        catch { notice = "重命名失败：\(error.localizedDescription)"; return false }
    }
    func deleteFavorite() {
        guard let selectedID else { return }
        let updated = favorites.filter { $0.id != selectedID }
        do {
            try favoritesStore.save(updated); favorites = updated; self.selectedID = nil
            notice = "收藏已删除，编辑区保留原命令"
        } catch { notice = "删除失败：\(error.localizedDescription)" }
    }
    func export() {
        guard let plan, !command.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "curl-request." + targetShell.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var data = Data()
            if targetShell == .powershell { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
            data.append(Data(try CurlShellService.script(plan, shell: targetShell, multiline: multiline, cmdStyle: cmdStyle, prettyJSON: true).utf8))
            try data.write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}

/// The existing on-disk library is shared by the debugger and the conversion sheet.
struct CurlFavoritesSidebar: View {
    @ObservedObject var model: CurlViewModel
    var busy = false
    var onLoad: (CurlFavorite) -> Void
    @State private var search = ""
    private var filtered: [CurlFavorite] {
        model.favorites.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || address($0).localizedCaseInsensitiveContains(search) }
    }
    private func address(_ item: CurlFavorite) -> String {
        guard let range = item.command.range(of: #"https?://[^\s'\"]+"#, options: .regularExpression),
              let host = URLComponents(string: String(item.command[range]))?.host else { return "cURL 命令" }
        return host
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("我的收藏").font(.system(size: 13, weight: .medium))
                Spacer()
                Button { model.reloadFavorites() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("重新读取收藏").accessibilityLabel("重新读取收藏")
                Text("\(model.favorites.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索名称或地址", text: $search).textFieldStyle(.plain)
            }.font(.system(size: 12)).padding(7).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            if let failure = model.favoritesError {
                Text(failure).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                Button("查看保存位置") { NSWorkspace.shared.selectFile(model.favoritesStorePath, inFileViewerRootedAtPath: "") }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if filtered.isEmpty {
                        Text(search.isEmpty ? "收藏常用 cURL，下次直接载入调试。" : "没有匹配的收藏")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    ForEach(filtered) { item in
                        Button { onLoad(item) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                Text(address(item)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedID == item.id ? Color.primary.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(busy).accessibilityLabel("载入收藏：\(item.name)")
                    }
                }
            }
            Text("仅保存在本机，载入不会自动发送。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(14).background(.secondary.opacity(0.035))
    }
}

struct CurlFavoriteActions: View {
    @ObservedObject var model: CurlViewModel
    var prepare: () -> Void
    @State private var sheet: FavoriteSheet?
    @State private var name = ""
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool
    private enum FavoriteSheet: String, Identifiable { case save, copy, rename; var id: String { rawValue } }
    var body: some View {
        HStack(spacing: 7) {
            Button {
                prepare()
                if let selected = model.selected { model.saveFavorite(name: selected.name, asNew: false) }
                else { open(.save) }
            } label: {
                Label(model.selected == nil ? "收藏" : model.modified ? "更新收藏" : "已收藏", systemImage: model.selected == nil ? "star" : "star.fill")
            }.disabled(!model.canSave || model.selected != nil && !model.modified)
                .keyboardShortcut("s", modifiers: .command)
            if model.selected != nil {
                Menu {
                    Button("重命名…") { open(.rename) }
                    Button("另存一份…") { prepare(); open(.copy) }.disabled(!model.canSave)
                    Divider()
                    Button("删除收藏…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    .disabled(model.favoritesError != nil).accessibilityLabel("管理当前收藏")
            }
        }
        .sheet(item: $sheet) { kind in
            VStack(alignment: .leading, spacing: 18) {
                Text(kind == .rename ? "重命名收藏" : kind == .copy ? "另存一份收藏" : "收藏这条 cURL")
                    .font(.system(size: 17, weight: .semibold))
                TextField("收藏名称", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused).onSubmit { submit(kind) }
                if kind != .rename {
                    Text("保存原始命令与来源终端，包括其中的鉴权信息。独立填写的 API Key 不会保存。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let notice = model.notice { Text(notice).font(.system(size: 12)).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("取消") { sheet = nil }.keyboardShortcut(.cancelAction)
                    Button(kind == .rename ? "保存名称" : "保存收藏") { submit(kind) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).count > 100)
                }
            }.padding(24).frame(width: 420).onAppear { model.notice = nil; nameFocused = true }
        }
        .confirmationDialog("删除这条收藏？编辑区中的命令会保留。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除收藏", role: .destructive) { model.deleteFavorite() }
        }
    }
    private func open(_ kind: FavoriteSheet) {
        name = kind == .rename ? model.selected?.name ?? "" : kind == .copy ? (model.selected?.name ?? "cURL") + " 副本" : ""
        sheet = kind
    }
    private func submit(_ kind: FavoriteSheet) {
        if kind == .rename ? model.renameFavorite(name) : model.saveFavorite(name: name, asNew: true) { sheet = nil }
    }
}

struct CurlConversionSheet: View {
    @ObservedObject var model: CurlViewModel
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("转换 cURL").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker("转换为", selection: $model.targetShell) {
                    ForEach(CurlShell.allCases, id: \.self) { Text($0.shortName).tag($0) }
                }.frame(maxWidth: 320)
                Spacer()
                Toggle("多行排版", isOn: $model.multiline).toggleStyle(.checkbox)
            }
            if model.targetShell == .cmd {
                Picker("命令形式", selection: $model.cmdStyle) {
                    ForEach(CurlCMDStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 420)
            }
            if model.checking { ProgressView("转换中…").controlSize(.small) }
            if let error = model.error { InlineMessage(message: error, error: true) }
            EditorPanel(title: "转换结果", text: .constant(model.command), editable: false).frame(minHeight: 240, maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(model.warnings, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: model.warnings.isEmpty ? 0 : 70)
            HStack {
                Button { state.copy(model.command) } label: { Label("复制命令", systemImage: "doc.on.doc") }.buttonStyle(.borderedProminent)
                Button("导出脚本…") { model.export() }
                Spacer()
                Text("只转换，不发送请求").font(.system(size: 11)).foregroundStyle(.secondary)
            }.disabled(model.command.isEmpty)
        }.padding(24).frame(minWidth: 620, idealWidth: 720, minHeight: 420, idealHeight: 540)
            .onAppear { model.scheduleImport() }
            .onDisappear { model.cancelImport() }
            .onChange(of: model.targetShell) { _, _ in model.refresh() }
            .onChange(of: model.multiline) { _, _ in model.refresh() }
            .onChange(of: model.cmdStyle) { _, _ in model.refresh() }
    }
}

extension CurlShell {
    var shortName: String {
        switch self { case .bash: "Linux / macOS"; case .cmd: "Windows CMD"; case .powershell: "PowerShell（5.1 / 7）" }
    }
}
