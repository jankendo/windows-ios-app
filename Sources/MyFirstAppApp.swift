import SwiftData
import SwiftUI

@main
struct ResonanceApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [MemoryEntry.self])
    }
}
