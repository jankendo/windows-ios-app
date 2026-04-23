import SwiftData
import SwiftUI

@main
struct ResonanceApp: App {
    private let modelContainer = ResonancePersistence.makeContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
