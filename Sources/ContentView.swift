import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3")
                .imageScale(.large)
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("Hello, Windows to iOS!")
                .font(.title2)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}

