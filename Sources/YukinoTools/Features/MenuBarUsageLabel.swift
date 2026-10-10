import SwiftUI
import YukinoCore

enum MenuBarUsageStyle: String, CaseIterable, Identifiable {
    case doubleRing, singleRing, bars, numbers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .doubleRing: return "双圆环"
        case .singleRing: return "单圆环"
        case .bars: return "横线"
        case .numbers: return "纯数字"
        }
    }
    var detail: String {
        switch self {
        case .doubleRing: return "外环 5h · 内环 7d"
        case .singleRing: return "右半 5h · 左半 7d"
        case .bars: return "上方 5h · 下方 7d"
        case .numbers: return "两行显示 · 更省空间"
        }
    }
}

struct MenuBarUsageLabel: View {
    let style: MenuBarUsageStyle
    let limits: CodexLimits?
    let recorded: Bool
    private var fiveHour: Double? { limits?.window(minutes: 300)?.fraction }
    private var weekly: Double? { limits?.window(minutes: 10080)?.fraction }
    private var description: String {
        let values = "Codex 已用 · 5h \(UsageFormat.percent(fiveHour)) · 7d \(UsageFormat.percent(weekly))"
        guard let limits else { return values + "\n用量暂不可用，点击菜单刷新。" }
        return values + "\n\(recorded ? "最近记录" : "账户数据") · \(limits.capturedAt.formatted(date: .abbreviated, time: .shortened))"
    }
    var body: some View {
        Image(nsImage: MenuBarUsageImage.make(style: style, fiveHour: fiveHour, weekly: weekly))
            .renderingMode(.template)
            .accessibilityLabel(description)
            .help(description)
    }
}

/// A template image keeps the complete two-line label at menu-bar height and follows macOS contrast.
enum MenuBarUsageImage {
    static func make(style: MenuBarUsageStyle, fiveHour: Double?, weekly: Double?) -> NSImage {
        func percentage(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "—" }
            return "\(Int((min(1, max(0, value)) * 100).rounded()))%"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        let first = NSAttributedString(string: "5h \(percentage(fiveHour))", attributes: attributes)
        let second = NSAttributedString(string: "7d \(percentage(weekly))", attributes: attributes)
        let textX: CGFloat = style == .numbers ? 1 : 29
        let size = NSSize(width: textX + max(first.size().width, second.size().width) + 2, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            func arc(radius: CGFloat, start: CGFloat, length: CGFloat, value: Double?) {
                let path = NSBezierPath()
                path.appendArc(withCenter: NSPoint(x: 12, y: 11), radius: radius,
                               startAngle: start, endAngle: start - length, clockwise: true)
                path.lineWidth = 2; path.lineCapStyle = .round
                if value == nil { path.setLineDash([1, 2], count: 2, phase: 0) }
                NSColor.black.withAlphaComponent(0.22).setStroke(); path.stroke()
                guard let value, value.isFinite, value > 0 else { return }
                let fill = NSBezierPath()
                fill.appendArc(withCenter: NSPoint(x: 12, y: 11), radius: radius,
                               startAngle: start, endAngle: start - length * min(1, max(0, value)), clockwise: true)
                fill.lineWidth = 2; fill.lineCapStyle = .round
                NSColor.black.setStroke(); fill.stroke()
            }
            func bar(y: CGFloat, value: Double?) {
                let track = NSBezierPath()
                track.move(to: NSPoint(x: 2, y: y)); track.line(to: NSPoint(x: 23, y: y))
                track.lineWidth = 2.5; track.lineCapStyle = .round
                if value == nil { track.setLineDash([1, 3], count: 2, phase: 0) }
                NSColor.black.withAlphaComponent(0.22).setStroke(); track.stroke()
                guard let value, value.isFinite, value > 0 else { return }
                let fill = NSBezierPath()
                fill.move(to: NSPoint(x: 2, y: y)); fill.line(to: NSPoint(x: 2 + 21 * min(1, max(0, value)), y: y))
                fill.lineWidth = 2.5; fill.lineCapStyle = .round
                NSColor.black.setStroke(); fill.stroke()
            }
            switch style {
            case .doubleRing:
                arc(radius: 9, start: 90, length: 360, value: fiveHour)
                arc(radius: 5, start: 90, length: 360, value: weekly)
            case .singleRing:
                arc(radius: 8.5, start: 85, length: 170, value: fiveHour)
                arc(radius: 8.5, start: 265, length: 170, value: weekly)
            case .bars:
                bar(y: 16, value: fiveHour); bar(y: 6, value: weekly)
            case .numbers: break
            }
            first.draw(at: NSPoint(x: textX, y: 10.5))
            second.draw(at: NSPoint(x: textX, y: 0))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "5h \(percentage(fiveHour)), 7d \(percentage(weekly))"
        return image
    }
}

struct MenuBarSettings: View {
    @EnvironmentObject private var usage: CodexUsageStore
    @AppStorage("menuBarUsageStyle") private var selectedStyle = MenuBarUsageStyle.doubleRing.rawValue
    @AppStorage("showMenuBar") private var showMenuBar = true
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("显示菜单栏用量", isOn: $showMenuBar)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(MenuBarUsageStyle.allCases) { style in
                    Button { selectedStyle = style.rawValue } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(style.title).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Image(systemName: selectedStyle == style.rawValue ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedStyle == style.rawValue ? Color.accentColor : Color.secondary)
                            }
                            MenuBarUsageLabel(style: style, limits: usage.limits, recorded: usage.limitIsRecorded)
                                .frame(height: 24)
                            Text(style.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedStyle == style.rawValue ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selectedStyle == style.rawValue ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(style.title + "，" + style.detail)
                        .accessibilityValue(selectedStyle == style.rawValue ? "已选择" : "未选择")
                }
            }
            Text("预览使用当前真实数据，显示已用比例。暂无数据以 — 和虚线表示；历史记录来源及重置时间可在菜单中查看。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(12).frame(maxHeight: .infinity, alignment: .top)
    }
}
