import SwiftUI

struct LocalToolDescriptor {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let group: String
    let aliases: String
}

// Private sources supply these integration points only for explicit local builds.
#if !YUKINO_LOCAL_FEATURES
enum LocalFeatureInfo {
    static let tools: [LocalToolDescriptor] = []
    static func preparePreferences() {}
}

@MainActor final class LocalFeatures: ObservableObject {
    func start(openWindow: OpenWindowAction) {}
}

struct LocalFeatureView: View {
    let id: String
    var body: some View { EmptyView() }
}

struct LocalFeatureMenu: View {
    var body: some View { EmptyView() }
}
#endif
