import SwiftUI
import YukinoCore

struct MarkdownReader: View {
    let blocks: [MarkdownBlock]
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(blocks) { block in blockView(block.kind, availableWidth: max(0, geometry.size.width - 48)) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
        .background(Color.panel)
        .environment(\.openURL, OpenURLAction { url in
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
            return .systemAction
        })
    }

    @ViewBuilder private func blockView(_ kind: MarkdownBlock.Kind, availableWidth: CGFloat) -> some View {
        switch kind {
        case .heading(let level, let text):
            inline(text).font(.system(size: level == 1 ? 24 : level == 2 ? 18 : 15, weight: .semibold))
                .padding(.top, level == 1 ? 0 : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let text): inline(text).font(.system(size: 13)).lineSpacing(4)
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.3)).frame(width: 3)
                inline(text).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true)
        case .list(let marker, let text, let indent):
            HStack(alignment: .top, spacing: 8) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                inline(text).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 13)).padding(.leading, CGFloat(indent) * 16)
        case .code(_, let text):
            ScrollView(.horizontal) {
                Text(text).font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: true, vertical: false).padding(14)
            }.background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        case .rule: Divider()
        case .table(let headers, let rows, let alignment):
            if headers == MarkdownDocument.openRouterRankingHeaders {
                combinedRankingTable(rows: rows, availableWidth: availableWidth)
            } else if headers.count == 6 && headers.contains("模型") && headers.contains("排名") && headers.contains("Tokens/wk") {
                rankingTable(headers: headers, rows: rows, availableWidth: availableWidth, comparison: false)
            } else if headers.count == 6 && headers.contains("排名今日") && headers.contains("排名变化") {
                rankingTable(headers: headers, rows: rows, availableWidth: availableWidth, comparison: true)
            } else {
                table(headers: headers, rows: rows, alignment: alignment)
            }
        }
    }
    @ViewBuilder private func combinedRankingTable(rows: [[String]], availableWidth: CGFloat) -> some View {
        let entries = rows.filter { $0.count == 9 && Int($0[0]) != nil }
        let maximum = entries.compactMap { tokenAmount($0[3]) }.max() ?? 0
        if availableWidth < 640 {
            VStack(spacing: 0) {
                ForEach(entries.indices, id: \.self) { index in
                    let row = entries[index]
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            inline(row[0]).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            combinedModel(row)
                        }
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("本周用量").font(.system(size: 10)).foregroundStyle(.secondary)
                                inline(row[3]).font(.system(size: 12, weight: .semibold))
                                tokenBar(row[3], maximum: maximum)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 6) {
                                Text("上次用量").font(.system(size: 10)).foregroundStyle(.secondary)
                                inline(row[4]).font(.system(size: 12))
                            }.frame(maxWidth: .infinity, alignment: .trailing)
                            VStack(alignment: .trailing, spacing: 6) {
                                Text("变化").font(.system(size: 10)).foregroundStyle(.secondary)
                                combinedChange(row)
                            }.frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }.padding(14).background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                    if index < entries.count - 1 { Divider() }
                }
            }.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline, lineWidth: 0.5))
        } else {
            let labels = ["排名", "模型", "本周用量", "上次用量", "变化"]
            let weights: [CGFloat] = [0, 0.44, 0.23, 0.15, 0.18]
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(labels.indices, id: \.self) { column in
                        Text(labels[column]).font(.system(size: 11, weight: .semibold))
                            .frame(width: rankingColumnWidth(column, weights: weights, availableWidth: availableWidth) - 16, alignment: column < 2 ? .leading : .trailing)
                            .padding(.horizontal, 8).padding(.vertical, 10)
                    }
                }.background(Color.primary.opacity(0.045))
                ForEach(entries.indices, id: \.self) { index in
                    HStack(alignment: .center, spacing: 0) {
                        ForEach(labels.indices, id: \.self) { column in
                            combinedRankingCell(entries[index], column: column, maximum: maximum)
                                .frame(width: rankingColumnWidth(column, weights: weights, availableWidth: availableWidth) - 16, alignment: column < 2 ? .leading : .trailing)
                                .padding(.horizontal, 8).padding(.vertical, 12)
                        }
                    }.background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                }
            }.frame(width: availableWidth)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline, lineWidth: 0.5))
        }
    }
    @ViewBuilder private func combinedRankingCell(_ row: [String], column: Int, maximum: Double) -> some View {
        switch column {
        case 1: combinedModel(row)
        case 2:
            VStack(alignment: .trailing, spacing: 7) {
                inline(row[3]).font(.system(size: 12, weight: .semibold))
                tokenBar(row[3], maximum: maximum)
            }
        case 3: inline(row[4]).font(.system(size: 12)).foregroundStyle(.secondary)
        case 4: combinedChange(row)
        default: inline(row[0]).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private func combinedModel(_ row: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                inline(row[1]).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                inline(row[8]).font(.system(size: 12))
            }
            HStack(spacing: 8) {
                inline(row[2])
                Text("· 上下文 \(row[7])")
            }.font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func combinedChange(_ row: [String]) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            inline(row[5]).font(.system(size: 12))
            Text("排名 \(row[6])").font(.system(size: 10)).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func inline(_ text: String) -> Text {
        var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(size: 12, design: .monospaced)
                attributed[run.range].foregroundColor = Color.accentColor
            }
        }
        return Text(attributed)
    }
    private func table(headers: [String], rows: [[String]], alignment: [MarkdownBlock.Alignment]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(headers.indices, id: \.self) { column in
                        inline(headers[column]).font(.system(size: 11, weight: .semibold))
                            .frame(width: width(headers[column]), alignment: cellAlignment(column, alignment))
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(.quaternary.opacity(0.5))
                    }
                }
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(headers.indices, id: \.self) { column in
                            inline(column < rows[row].count ? rows[row][column] : "")
                                .font(.system(size: 12))
                                .frame(width: width(headers[column]), alignment: cellAlignment(column, alignment))
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(row.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                        }
                    }
                }
            }
        }.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline, lineWidth: 0.5))
    }
    /// Ranking summaries fit the reader width; the full capability matrix retains its scrollable columns.
    @ViewBuilder private func rankingTable(headers: [String], rows: [[String]], availableWidth: CGFloat, comparison: Bool) -> some View {
        let entries = rows.filter { $0.count >= headers.count && Int($0[0]) != nil }
        let maximum = entries.compactMap { tokenAmount($0[3]) }.max() ?? 0
        if availableWidth < 640 {
            VStack(spacing: 0) {
                ForEach(entries.indices, id: \.self) { index in
                    rankingCard(entries[index], comparison: comparison, maximum: maximum)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                    if index < entries.count - 1 { Divider() }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline, lineWidth: 0.5))
        } else {
            let weights: [CGFloat] = comparison ? [0.055, 0.32, 0.115, 0.245, 0.145, 0.12] : [0.055, 0.35, 0.15, 0.265, 0.12, 0.06]
            let labels = comparison ? ["排名", "模型", "提供方", "周 Tokens：上次 → 今日", "变化", "排名变化"] : ["排名", "模型", "提供方", "Tokens/wk", "上下文", "详情"]
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(labels.indices, id: \.self) { column in
                        Text(labels[column]).font(.system(size: 11, weight: .semibold))
                            .frame(width: rankingColumnWidth(column, weights: weights, availableWidth: availableWidth) - 16, alignment: column < 3 ? .leading : .trailing)
                            .padding(.horizontal, 8).padding(.vertical, 10)
                    }
                }.background(Color.primary.opacity(0.045))
                ForEach(entries.indices, id: \.self) { index in
                    HStack(alignment: .center, spacing: 0) {
                        ForEach(labels.indices, id: \.self) { column in
                            VStack(alignment: .trailing, spacing: 7) {
                                inline(entries[index][column]).font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                                if !comparison && column == 3 { tokenBar(entries[index][3], maximum: maximum) }
                            }
                            .frame(width: rankingColumnWidth(column, weights: weights, availableWidth: availableWidth) - 16, alignment: column < 3 ? .leading : .trailing)
                            .padding(.horizontal, 8).padding(.vertical, 12)
                        }
                    }.background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                }
            }
            .frame(width: availableWidth)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline, lineWidth: 0.5))
        }
    }
    private func rankingColumnWidth(_ column: Int, weights: [CGFloat], availableWidth: CGFloat) -> CGFloat {
        // Keep the two-character rank heading together at the minimum window width.
        column == 0 ? 44 : (availableWidth - 44) * weights[column] / (1 - weights[0])
    }
    private func rankingCard(_ row: [String], comparison: Bool, maximum: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(row[0]).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    inline(row[1]).font(.system(size: 13, weight: .semibold))
                    inline(row[2]).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !comparison { inline(row[5]).font(.system(size: 12)) }
            }
            if comparison {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("周 Tokens").foregroundStyle(.secondary)
                        Spacer(minLength: 8); inline(row[3])
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("变化").foregroundStyle(.secondary); inline(row[4])
                        Spacer(minLength: 8)
                        Text("排名").foregroundStyle(.secondary); inline(row[5])
                    }
                }.font(.system(size: 12))
            } else {
                HStack(alignment: .firstTextBaseline) {
                    inline(row[3]).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("上下文").foregroundStyle(.secondary); inline(row[4])
                }.font(.system(size: 12))
                tokenBar(row[3], maximum: maximum)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func tokenBar(_ value: String, maximum: Double) -> some View {
        let ratio = maximum > 0 ? min(1, max(0, (tokenAmount(value) ?? 0) / maximum)) : 0
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.accentColor.opacity(0.08))
                Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: geometry.size.width * ratio)
            }
        }.frame(height: 4).accessibilityHidden(true)
    }
    private func tokenAmount(_ source: String) -> Double? {
        let text = String(((try? AttributedString(markdown: source)) ?? AttributedString(source)).characters).trimmingCharacters(in: .whitespaces)
        let scales: [Character: Double] = ["T": 1e12, "B": 1e9, "M": 1e6, "K": 1e3]
        let amount: Double?
        if let suffix = text.last, let scale = scales[suffix], let number = Double(text.dropLast()) { amount = number * scale }
        else { amount = Double(text) }
        return amount.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
    private func width(_ header: String) -> CGFloat {
        switch header {
        case "#", "排名", "排名今日": 38
        case "模型 ID": 265
        case "模型", "名称": 210
        case "详情": 40
        case "工具", "结构化": 50
        case "输入": 130
        case "输出", "提供方", "上下文", "标记", "排名变化", "变化": 90
        case "Tokens/wk": 310 // Fits the original forty-character bars without wrapping.
        default: 205
        }
    }
    private func cellAlignment(_ column: Int, _ values: [MarkdownBlock.Alignment]) -> Alignment {
        guard column < values.count else { return .leading }
        switch values[column] { case .left: return .leading; case .center: return .center; case .right: return .trailing }
    }
}
