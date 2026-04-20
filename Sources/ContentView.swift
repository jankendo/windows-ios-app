import SwiftUI

struct ContentView: View {
    @State private var selectedTab: ResonanceTab = .capture

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CaptureView()
            }
            .tabItem {
                Label("Capture", systemImage: "camera.viewfinder")
            }
            .tag(ResonanceTab.capture)

            NavigationStack {
                LibraryView()
            }
            .tabItem {
                Label("Library", systemImage: "square.stack.3d.down.right")
            }
            .tag(ResonanceTab.library)

            NavigationStack {
                SearchView()
            }
            .tabItem {
                Label("Search", systemImage: "waveform.and.magnifyingglass")
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
