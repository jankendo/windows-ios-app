import SwiftUI

struct ContentView: View {
    @State private var selectedTab: ResonanceTab = .capture

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CaptureView(isActive: selectedTab == .capture)
            }
            .tabItem {
                Label("記録", systemImage: "camera.viewfinder")
            }
            .tag(ResonanceTab.capture)

            NavigationStack {
                LibraryView()
            }
            .tabItem {
                Label("ライブラリ", systemImage: "photo.stack")
            }
            .tag(ResonanceTab.library)

            NavigationStack {
                SearchView()
            }
            .tabItem {
                Label("検索", systemImage: "magnifyingglass")
            }
            .tag(ResonanceTab.search)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("設定", systemImage: "gearshape")
            }
            .tag(ResonanceTab.settings)
        }
        .tint(.indigo)
    }
}

private enum ResonanceTab: Hashable {
    case capture
    case library
    case search
    case settings
}

#Preview {
    ContentView()
        .modelContainer(ResonancePersistence.makeContainer(inMemory: true))
}
