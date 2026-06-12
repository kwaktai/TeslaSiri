import AppIntents
import FleetKit
import SwiftUI

struct AppIntentDiscoveryCard: View {
    @State private var isStatusTipVisible = true

    var body: some View {
        CardContainer(title: "Siri & Shortcuts", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Control your Tesla hands-free — status, lock, climate, software, horn, lights, and navigation work from Siri, Spotlight, and the Shortcuts app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SiriTipView(intent: GetVehicleStatusIntent(), isVisible: $isStatusTipVisible)
                    .siriTipViewStyle(.automatic)

                ShortcutsLink()
                    .shortcutsLinkStyle(.automatic)
            }
        }
    }
}

#Preview {
    AppIntentDiscoveryCard()
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}
