import SwiftUI

extension Color {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: NSColor(name: NSColor.Name("YukinoPanel")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.21, alpha: 1)
            : NSColor.controlBackgroundColor
    })
    static let hairline = Color(nsColor: .separatorColor).opacity(0.45)
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.hairline, lineWidth: 0.5))
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 28, weight: .semibold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolPage<Content: View>: View {
    let tool: Tool
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: tool.title, subtitle: tool.subtitle)
                content
            }.padding(32)
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .background(Color.canvas)
    }
}

struct SymbolTile: View {
    let symbol: String
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
    }
}

struct UsageSourceBadge: View {
    @EnvironmentObject private var usage: CodexUsageStore
    var body: some View {
        Label(usage.status.uppercased(), systemImage: usage.status == "Connected" ? "checkmark.circle" : "clock.arrow.circlepath")
            .font(.system(size: 10, weight: .semibold)).tracking(0.8)
            .foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 5)
            .background(.secondary.opacity(0.08), in: Capsule())
    }
}

struct InlineMessage: View {
    let message: String
    var error = false
    var body: some View {
        Label(message, systemImage: error ? "exclamationmark.circle" : "checkmark.circle")
            .font(.system(size: 12)).foregroundStyle(error ? Color.orange : Color.secondary)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HoverCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverBody(configuration: configuration) }
    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered ? Color.accentColor.opacity(0.08) : Color.panel, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hovered ? Color.accentColor.opacity(0.3) : Color.hairline, lineWidth: 0.5))
                .opacity(configuration.isPressed ? 0.75 : 1)
                .onHover { inside in
                    hovered = inside
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .animation(.easeOut(duration: 0.16), value: hovered)
        }
    }
}

struct FavoriteMenu: View {
    @EnvironmentObject private var state: AppState
    let tool: Tool
    var body: some View {
        Button {
            state.toggleFavorite(tool)
        } label: {
            Label(state.favorites.contains(tool) ? "Remove from Favorites" : "Add to Favorites", systemImage: state.favorites.contains(tool) ? "star.slash" : "star")
        }
    }
}
