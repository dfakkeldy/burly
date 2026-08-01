// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import BurlyCore

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 48))
            Text("Burly")
                .font(.largeTitle.bold())
            Text("Watch-first lifting tracker")
                .foregroundStyle(.secondary)
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
