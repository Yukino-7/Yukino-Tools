import SwiftUI
import Charts
import YukinoCore

struct OverviewView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var usage: CodexUsageStore
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    PageHeader(title: "\(greeting) ☀︎", subtitle: "Your personal developer toolbox. Everything in its place.")
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(Date(), format: .dateTime.weekday(.wide).month(.abbreviated).day())
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        UsageSourceBadge()
                    }.padding(.top, 5)
                }
                HStack(spacing: 16) {
                    MetricCard(title: "Codex Usage", value: UsageFormat.percent(usage.limits?.primary?.fraction),
                        detail: usage.limitIsRecorded ? "Recorded snapshot" : UsageFormat.windowTitle(usage.limits?.primary, fallback: "Account limit"), symbol: "terminal", progress: usage.limits?.primary?.fraction)
                    MetricCard(title: "Context", value: UsageFormat.percent(usage.latestSession?.contextFraction),
                        detail: "Latest request · estimated", symbol: "square.stack", progress: usage.latestSession?.contextFraction)
                    MetricCard(title: "Cache Hit", value: UsageFormat.percent(usage.ready ? usage.todayTotals.cacheHit : nil),
                        detail: "Local input tokens · today", symbol: "bolt", progress: usage.ready ? usage.todayTotals.cacheHit : nil)
                    MetricCard(title: "Sessions", value: usage.ready ? "\(usage.todaySessions)" : "—",
                        detail: "Active today on this Mac", symbol: "rectangle.on.rectangle", progress: nil)
                }
                CodexStatusRow()
                UsageChartPanel()
                HStack {
                    Text("Frequently used").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Text("Your everyday essentials").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
                    ForEach([Tool.json, .base64, .timestamp, .uuid]) { tool in
                        Button { state.navigate(tool) } label: {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack { SymbolTile(symbol: tool.symbol); Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.tertiary) }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tool.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                                    Text(tool.group).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }.buttonStyle(HoverCardStyle()).contextMenu { FavoriteMenu(tool: tool) }
                    }
                }
                recentPanel
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text("Built for your Mac. Conversions stay on your device.")
                    Spacer()
                    Text("YUKINO / 0.3").tracking(1.2)
                }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 4)
            }.padding(32)
        }.contentMargins(.top, 0, for: .scrollContent).background(Color.canvas)
    }
    private var recentPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Recently opened").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.tertiary)
                }
                if state.recent.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").foregroundStyle(.secondary)
                        Text("A fresh workspace. Open a tool to start your history.").foregroundStyle(.secondary)
                    }.font(.system(size: 12)).padding(.vertical, 12)
                } else {
                    ForEach(Array(state.recent.prefix(3))) { item in
                        Button { state.navigate(item.tool) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.tool.symbol).foregroundStyle(.secondary).frame(width: 22)
                                Text(item.tool.title).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(item.date, style: .relative).font(.system(size: 11)).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }.contentShape(Rectangle()).padding(.vertical, 4)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let progress: Double?
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.tertiary)
                }
                Text(value).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                HStack {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if let progress {
                        ProgressView(value: progress).progressViewStyle(.linear).frame(width: 42)
                    }
                }
            }
        }
    }
}

struct UsageChartPanel: View {
    @State private var days = 7
    @State private var hoveredDate: Date?
    @EnvironmentObject private var usage: CodexUsageStore
    private var points: [UsagePoint] { usage.points(days: days) }
    private var hoveredPoint: UsagePoint? { points.first { $0.date == hoveredDate } }
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Token activity").font(.system(size: 16, weight: .semibold))
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(usage.ready ? total : "—").font(.system(size: 24, weight: .semibold, design: .rounded))
                            Text("tokens · local logs").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Picker("Period", selection: $days) {
                        Text("Today").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                    }.pickerStyle(.segmented).frame(width: 205).labelsHidden()
                }
                if !usage.ready {
                    ContentUnavailableView("Loading local activity", systemImage: "chart.xyaxis.line", description: Text(usage.localError ?? "Reading Codex token counters…"))
                        .frame(height: 160)
                } else if points.allSatisfy({ $0.tokens == 0 }) {
                    ContentUnavailableView("No recorded activity", systemImage: "chart.xyaxis.line", description: Text("No local token records for this period."))
                        .frame(height: 160)
                } else {
                Chart {
                    ForEach(points) { point in
                        AreaMark(x: .value("Date", point.date), y: .value("Tokens", point.tokens))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.2), Color.accentColor.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Date", point.date), y: .value("Tokens", point.tokens))
                            .interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2.5))
                            .foregroundStyle(Color.accentColor)
                    }
                    if let point = hoveredPoint {
                        RuleMark(x: .value("Date", point.date))
                            .foregroundStyle(.secondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .accessibilityHidden(true)
                        PointMark(x: .value("Date", point.date), y: .value("Tokens", point.tokens))
                            .foregroundStyle(Color.accentColor)
                            .symbolSize(50)
                            .accessibilityHidden(true)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                        AxisValueLabel {
                            if let number = value.as(Double.self) { Text(UsageFormat.tokens(Int64(number))).font(.system(size: 10)) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: days == 7 ? 7 : 6)) { value in
                        AxisValueLabel(format: days == 1 ? .dateTime.hour() : days == 7 ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day())
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let frame = proxy.plotFrame {
                            let plot = geometry[frame]
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        guard plot.contains(location),
                                              let date = proxy.value(atX: location.x - plot.minX, as: Date.self) else {
                                            hoveredDate = nil
                                            return
                                        }
                                        hoveredDate = points.min {
                                            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                        }?.date
                                    case .ended: hoveredDate = nil
                                    }
                                }
                            if let point = hoveredPoint, let x = proxy.position(forX: point.date) {
                                let width = min(220, plot.width)
                                hoverLabel(for: point)
                                    .frame(width: width)
                                    .position(x: min(max(plot.minX + x, plot.minX + width / 2), plot.maxX - width / 2),
                                              y: plot.minY + 34)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .frame(height: 160)
                }
            }
        }.onChange(of: days) { _, _ in hoveredDate = nil }
    }
    private func hoverLabel(for point: UsagePoint) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(point.date, format: .dateTime.year().month().day())
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if days == 1 {
                let end = Calendar.current.date(byAdding: .hour, value: 1, to: point.date) ?? point.date
                Text("\(point.date.formatted(.dateTime.hour().minute()))–\(end.formatted(.dateTime.hour().minute()))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("\(point.tokens.formatted()) tokens")
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
    }
    private var total: String {
        let value = points.reduce(0) { $0 + $1.tokens }
        return UsageFormat.tokens(value)
    }
}
