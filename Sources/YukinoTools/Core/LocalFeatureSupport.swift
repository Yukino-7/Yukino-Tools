import SwiftUI

// Private sources supply these integration points only for explicit local builds.
#if !YUKINO_LOCAL_FEATURES
enum LocalFeatureInfo {
    static let available = false
    static let title = "Local Features"
    static let subtitle = ""
    static let symbol = "square.dashed"
    static let group = "Workspace"
    static let aliases = ""
    static func preparePreferences() {}
}

@MainActor final class LocalFeatures: ObservableObject {
    func start(openWindow: OpenWindowAction) {}
}

struct LocalFeatureView: View {
    var body: some View { EmptyView() }
}

struct LocalFeatureMenu: View {
    var body: some View { EmptyView() }
}
#endif
