import SwiftUI
import YukinoCore

struct CodexStatusRow: View {
    @EnvironmentObject private var usage: CodexUsageStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                UsageSourceBadge()
                if let captured = usage.limits?.capturedAt {
                    Text("\(usage.limits?.source ?? "") · \(captured.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text(usage.accountRefreshing ? "Reading account allowance…" : "Account allowance unavailable")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await usage.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }.disabled(usage.scanning || usage.accountRefreshing).controlSize(.small)
            }
            if let error = usage.localError { InlineMessage(message: error, error: true) }
            if let error = usage.accountError { InlineMessage(message: error, error: true) }
            if usage.local.unreadableFiles > 0 || usage.local.malformedLines > 0 {
                Text("Local scan: \(usage.local.unreadableFiles) unreadable files, \(usage.local.malformedLines) skipped metadata/usage lines. Totals may be incomplete.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

struct CodexUsageView: View {
    @EnvironmentObject private var usage: CodexUsageStore
    @State private var session: CodexSession?
    @State private var query = ""
    @State private var sessionCount = 50
    private var filtered: [CodexSession] {
        usage.local.sessions.filter {
            query.isEmpty || "\($0.project) \($0.id) \($0.model ?? "")".localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        ToolPage(tool: .codex) {
            CodexStatusRow()
            HStack(spacing: 20) {
                LimitPanel(window: usage.limits?.primary, title: UsageFormat.windowTitle(usage.limits?.primary, fallback: "Primary limit"))
                LimitPanel(window: usage.limits?.secondary, title: UsageFormat.windowTitle(usage.limits?.secondary, fallback: "Secondary limit"))
            }
            HStack {
                Text("Local session totals").font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("Active + archived · on this Mac").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                MetricCard(title: "Input tokens", value: count(usage.local.totals.input), detail: "Includes cached input", symbol: "arrow.down", progress: nil)
                MetricCard(title: "Output tokens", value: count(usage.local.totals.output), detail: "Includes reasoning", symbol: "arrow.up", progress: nil)
                MetricCard(title: "Cached tokens", value: count(usage.local.totals.cached), detail: "Subset of input", symbol: "bolt", progress: nil)
                MetricCard(title: "Cache hit", value: UsageFormat.percent(usage.ready ? usage.local.totals.cacheHit : nil), detail: "Cached / input", symbol: "sparkles", progress: nil)
            }
            UsageChartPanel()
            Panel {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Session usage").font(.system(size: 17, weight: .semibold))
                        Spacer()
                        Text("\(usage.local.sessions.count) local sessions").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("Filter sessions", text: $query).textFieldStyle(.roundedBorder).frame(width: 180)
                    }
                    HStack {
                        Text("PROJECT / SESSION").frame(maxWidth: .infinity, alignment: .leading)
                        Text("TOKENS").frame(width: 90, alignment: .trailing)
                        Text("LAST CONTEXT · EST.").frame(width: 180, alignment: .trailing)
                    }.font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
                    Divider()
                    if filtered.isEmpty {
                        Text(usage.scanning ? "Reading local sessions…" : query.isEmpty ? "No local session metadata found." : "No matching sessions.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                    LazyVStack(spacing: 14) {
                        ForEach(Array(filtered.prefix(sessionCount))) { item in
                            Button { session = item } label: {
                                HStack(spacing: 12) {
                                    SymbolTile(symbol: "terminal", size: 30)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.project).font(.system(size: 12, weight: .medium))
                                        Text("\(item.id.prefix(8)) · \(item.model ?? "Unknown model")\(item.archived ? " · Archived" : "")")
                                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Text(UsageFormat.tokens(item.tokens.total)).font(.system(size: 12, design: .monospaced)).frame(width: 90, alignment: .trailing)
                                    HStack(spacing: 12) {
                                        if let fraction = item.contextFraction { ProgressView(value: fraction).frame(width: 80) }
                                        Text(UsageFormat.percent(item.contextFraction)).font(.system(size: 11)).monospacedDigit().frame(width: 45)
                                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                                    }.frame(width: 180, alignment: .trailing)
                                }.contentShape(Rectangle()).padding(.vertical, 4)
                            }.buttonStyle(.plain)
                        }
                    }
                    if filtered.count > sessionCount {
                        Button("Show more sessions") { sessionCount += 50 }
                    }
                    if let scanned = usage.localUpdatedAt {
                        Text("Scanned \(usage.local.scannedFiles) logs at \(scanned.formatted(date: .omitted, time: .standard)). Token totals cover locally recorded activity, including archives.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: query) { _, _ in sessionCount = 50 }
        .sheet(item: $session) { item in SessionDetailView(session: item) }
    }
    private func count(_ value: Int64) -> String { usage.ready ? UsageFormat.tokens(value) : "—" }
}

struct LimitPanel: View {
    @EnvironmentObject private var usage: CodexUsageStore
    let window: CodexLimitWindow?
    let title: String
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text(UsageFormat.percent(window?.fraction)).font(.system(size: 28, weight: .semibold, design: .rounded))
                }
                if let window { ProgressView(value: window.fraction) }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if let reset = window?.resetDate {
                        if reset > context.date {
                            Text("Resets \(reset, style: .relative) · \(reset.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            Text("Snapshot predates reset · Refresh to update")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    } else {
                        Text(window == nil ? "Not available" : "Reset time not provided")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if usage.limitIsRecorded { Text("Last recorded value").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
    }
}

struct SessionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var usage: CodexUsageStore
    let session: CodexSession
    private var current: CodexSession { usage.local.sessions.first { $0.id == session.id } ?? session }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                SymbolTile(symbol: "terminal")
                PageHeader(title: current.project, subtitle: "Local Codex session")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(current.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            LabeledContent("Project", value: current.directory).textSelection(.enabled)
            LabeledContent("Model", value: current.model ?? "Not recorded")
            LabeledContent("Input tokens", value: current.tokens.input.formatted())
            LabeledContent("Cached input", value: current.tokens.cached.formatted())
            LabeledContent("Output tokens", value: current.tokens.output.formatted())
            LabeledContent("Reasoning (included in output)", value: current.tokens.reasoning.formatted())
            LabeledContent("Last request context", value: UsageFormat.percent(current.contextFraction))
            if let fraction = current.contextFraction { ProgressView(value: fraction) }
            if let tokens = current.contextTokens, let window = current.contextWindow {
                Text("\(tokens.formatted()) / \(window.formatted()) tokens · latest recorded request, not a live editor measurement.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            LabeledContent("Last token record", value: current.lastActivity.formatted(date: .abbreviated, time: .standard))
            LabeledContent("Status", value: current.archived ? "Archived" : "Local session")
        }.padding(28).frame(width: 590)
    }
}
