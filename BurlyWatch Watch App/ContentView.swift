import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 28))
            Text("Burly")
                .font(.headline)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
