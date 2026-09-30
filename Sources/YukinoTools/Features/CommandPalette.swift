import SwiftUI

struct CommandPalette: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool
    private var tools: [Tool] {
        if query.isEmpty {
            let recent = state.recent.map(\.tool)
            return recent + Tool.allCases.filter { !recent.contains($0) }
        }
        return Tool.allCases.filter { $0.matches(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(.secondary)
                TextField("Search tools and commands…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 17)).focused($focused)
                    .onSubmit { openSelection() }
                Button("esc") { dismiss() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(22)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(query.isEmpty ? "TOOLS & RECENTLY USED" : "RESULTS")
                            .font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary).padding(10)
                        ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                            Button { state.navigate(tool) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: tool.symbol).frame(width: 22).foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tool.title).fontWeight(.medium)
                                        Text(tool.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(tool.available ? tool.group : "Planned").font(.system(size: 10)).foregroundStyle(.secondary)
                                    if index == selectedIndex { Image(systemName: "return").foregroundStyle(.secondary) }
                                }.padding(12).contentShape(Rectangle())
                                    .background(index == selectedIndex ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).id(index)
                        }
                        if tools.isEmpty {
                            ContentUnavailableView.search(text: query).padding(.vertical, 20)
                        }
                    }.padding(12)
                }.frame(height: 360)
                    .onChange(of: selectedIndex) { _, index in proxy.scrollTo(index) }
            }
            Divider()
            HStack {
                Text("↑ ↓ to navigate   ↵ to open")
                Spacer()
                Text("Yukino Tools")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(14)
        }.frame(width: 580)
            .onAppear { focused = true }
            .onChange(of: query) { _, _ in selectedIndex = 0 }
            .onKeyPress(.downArrow) {
                selectedIndex = min(selectedIndex + 1, max(0, tools.count - 1)); return .handled
            }
            .onKeyPress(.upArrow) { selectedIndex = max(selectedIndex - 1, 0); return .handled }
            .onExitCommand { dismiss() }
    }
    private func openSelection() {
        guard tools.indices.contains(selectedIndex) else { return }
        state.navigate(tools[selectedIndex])
    }
}
