// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import BurlyCore

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 28))
            Text("Burly")
                .font(.headline)
        }
        .padding()
        .onAppear {
            _ = BurlyCore.placeholder
        }
    }
}

#Preview {
    ContentView()
}
