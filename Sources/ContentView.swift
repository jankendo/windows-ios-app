import SwiftUI

struct ContentView: View {
    @State private var selectedTab: ResonanceTab = .capture

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CaptureView()
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
        }
        .tint(.indigo)
    }
}

private enum ResonanceTab: Hashable {
    case capture
    case library
    case search
}

#Preview {
    ContentView()
        .modelContainer(for: [MemoryEntry.self], inMemory: true)
}
