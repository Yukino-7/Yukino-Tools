import SwiftUI
import YukinoCore

enum WorkPilotStyle {
    static let green = adaptive(light: NSColor(red: 0.25, green: 0.46, blue: 0.32, alpha: 1), dark: NSColor(red: 0.52, green: 0.74, blue: 0.58, alpha: 1))
    static let amber = adaptive(light: NSColor(red: 0.61, green: 0.39, blue: 0.10, alpha: 1), dark: NSColor(red: 0.83, green: 0.66, blue: 0.36, alpha: 1))
    static let red = adaptive(light: NSColor(red: 0.65, green: 0.32, blue: 0.30, alpha: 1), dark: NSColor(red: 0.84, green: 0.56, blue: 0.53, alpha: 1))
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static func color(_ status: WorkStatus?) -> Color {
        switch status { case .done: green; case .todo: amber; case .blocked: red; default: .secondary }
    }
    static func title(_ status: WorkStatus?) -> String {
        switch status { case .todo: "待跟进"; case .doing: "进行中"; case .blocked: "阻塞"; case .done: "已完成"; case nil: "记录" }
    }
    static func symbol(_ status: WorkStatus?) -> String {
        switch status { case .todo: "clock"; case .doing: "ellipsis.circle"; case .blocked: "exclamationmark.circle"; case .done: "checkmark.circle"; case nil: "square.and.pencil" }
    }
}

struct WorkCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.hairline, lineWidth: 0.5))
    }
}

private struct WorkModuleMetrics: Equatable {
    var height: CGFloat = 0
    var offset: CGFloat = 0
}
private struct WorkModuleMeasurement: PreferenceKey {
    static let defaultValue = WorkModuleMetrics()
    static func reduce(value: inout WorkModuleMetrics, nextValue: () -> WorkModuleMetrics) {
        let next = nextValue()
        if next.height > 0, next.height >= value.height { value = next }
    }
}

@MainActor
private final class WorkModuleScrollHandle {
    weak var scrollView: NSScrollView?
    func scroll(to offset: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(maximum, max(0, offset))))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// Locate the module's native scroll view for thumb dragging without changing app-wide preferences.
private struct WorkModuleScrollAnchor: NSViewRepresentable {
    let handle: WorkModuleScrollHandle
    final class Anchor: NSView {
        var handle: WorkModuleScrollHandle?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); handle?.scrollView = enclosingScrollView }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); handle?.scrollView = enclosingScrollView }
    }
    func makeNSView(context: Context) -> Anchor { let view = Anchor(); view.handle = handle; return view }
    func updateNSView(_ view: Anchor, context: Context) { handle.scrollView = view.enclosingScrollView }
}

/// Short modules stay compact; overflow uses a hover-only thumb that never reserves layout space.
struct WorkModuleScroll<Content: View>: View {
    let maxHeight: CGFloat
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    @State private var metrics = WorkModuleMetrics()
    @State private var hovered = false
    @State private var dragOrigin: CGFloat?
    @State private var scrollHandle = WorkModuleScrollHandle()
    @Namespace private var scrollSpace
    private var viewportHeight: CGFloat { metrics.height > 0 ? min(metrics.height, maxHeight) : maxHeight }
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: spacing) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(WorkModuleScrollAnchor(handle: scrollHandle))
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: WorkModuleMeasurement.self,
                        value: WorkModuleMetrics(height: geometry.size.height, offset: -geometry.frame(in: .named(scrollSpace)).minY))
                })
        }
        .coordinateSpace(name: scrollSpace)
        .frame(height: viewportHeight)
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .overlay(alignment: .trailing) {
            if metrics.height > viewportHeight + 1 {
                let thumbHeight = min(viewportHeight, max(24, viewportHeight * viewportHeight / metrics.height))
                let travel = viewportHeight - thumbHeight
                let range = metrics.height - viewportHeight
                let position = min(1, max(0, metrics.offset / range)) * travel
                Capsule().fill(Color.secondary.opacity(dragOrigin == nil ? 0.45 : 0.7))
                    .frame(width: 5, height: thumbHeight)
                    .frame(width: 10).contentShape(Rectangle())
                    .offset(y: position - travel / 2)
                    .opacity(hovered || dragOrigin != nil ? 1 : 0)
                    .allowsHitTesting(hovered || dragOrigin != nil)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(scrollSpace))
                        .onChanged { value in
                            if dragOrigin == nil { dragOrigin = metrics.offset }
                            if travel > 0 { scrollHandle.scroll(to: (dragOrigin ?? 0) + value.translation.height * range / travel) }
                        }.onEnded { _ in dragOrigin = nil })
                    .accessibilityLabel("滚动列表")
                    .accessibilityValue("\(Int(min(1, max(0, metrics.offset / range)) * 100))%")
                    .accessibilityAdjustableAction { direction in
                        scrollHandle.scroll(to: metrics.offset + (direction == .increment ? viewportHeight * 0.8 : -viewportHeight * 0.8))
                    }
            }
        }
        .onHover { hovered = $0 }
        .onPreferenceChange(WorkModuleMeasurement.self) { metrics = $0 }
    }
}

struct WorkStatusBadge: View {
    let status: WorkStatus?
    var body: some View {
        Label(WorkPilotStyle.title(status), systemImage: WorkPilotStyle.symbol(status))
            .font(.system(size: 10, weight: .medium)).foregroundStyle(WorkPilotStyle.color(status))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(WorkPilotStyle.color(status).opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct WorkProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.13))
                if value > 0 {
                    Capsule().fill(Color.secondary.opacity(0.55)).frame(width: proxy.size.width * min(1, value))
                }
            }
        }.frame(height: 4)
    }
}

struct WorkRecordRow: View {
    let entry: WorkRecordEntry
    let projectName: String?
    var supplementalDetail = ""
    var compact = false
    let toggle: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    let changeStatus: (WorkStatus?) -> Void
    @State private var expanded = false
    @State private var statusPickerVisible = false
    private var details: String { [entry.detail, supplementalDetail].filter { !$0.isEmpty && $0 != "已完成" }.joined(separator: "\n") }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: toggle) {
                Image(systemName: entry.status == .done ? "checkmark.circle.fill" : entry.status == nil ? "square.and.pencil" : "circle")
                    .font(.system(size: compact ? 15 : 17)).foregroundStyle(WorkPilotStyle.color(entry.status))
                    .frame(width: 20, height: 22)
            }.buttonStyle(.plain)
                .accessibilityLabel("\(entry.status == .done ? "重新跟进" : "标记完成")：\(entry.title)")
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.title).font(.system(size: 13, weight: compact ? .regular : .medium))
                    .lineLimit(expanded ? nil : (compact ? 1 : 2)).textSelection(.enabled)
                if !compact || expanded {
                    HStack(spacing: 8) {
                        Text(entry.date, style: .time)
                        if let projectName { Label(projectName, systemImage: "folder").lineLimit(1) }
                        if case .log(let log) = entry, log.gitCommit != nil { Text("Git") }
                        if case .log(let log) = entry, log.codexActivityID != nil { Text("Codex 会话") }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if expanded, !details.isEmpty { Text(details).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if !compact, !details.isEmpty || entry.title.count > 90 || entry.title.contains("\n") {
                    Button(expanded ? "收起" : "展开内容") { expanded.toggle() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { statusPickerVisible = true } label: {
                HStack(spacing: 3) {
                    WorkStatusBadge(status: entry.status)
                    Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain).fixedSize()
                .accessibilityLabel("状态：\(WorkPilotStyle.title(entry.status))")
                .popover(isPresented: $statusPickerVisible) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(WorkStatus.allCases, id: \.self) { status in
                            Button { changeStatus(status); statusPickerVisible = false } label: {
                                HStack {
                                    Label(WorkPilotStyle.title(status), systemImage: WorkPilotStyle.symbol(status))
                                        .foregroundStyle(WorkPilotStyle.color(status))
                                    Spacer()
                                    if entry.status == status { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                                }.padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if case .log = entry {
                            Divider()
                            Button { changeStatus(nil); statusPickerVisible = false } label: {
                                Text("仅作记录").padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.font(.system(size: 12)).padding(7).frame(width: 160)
                }
            if !compact {
                Menu {
                    Button("编辑内容", action: edit)
                    Button("删除", role: .destructive, action: delete)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
        }.padding(.vertical, compact ? 7 : 12)
    }
}

struct WorkMetric: View {
    let title: String
    let value: String
    let symbol: String
    var color: Color = .secondary
    var valueColor: Color = .primary
    var body: some View {
        WorkCard {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 23, weight: .regular)).foregroundStyle(color).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(value).font(.system(size: 23, weight: .semibold)).foregroundStyle(valueColor).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
        }
    }
}
