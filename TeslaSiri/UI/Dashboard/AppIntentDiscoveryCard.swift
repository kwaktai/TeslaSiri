import AppIntents
import FleetKit
import SwiftUI

struct AppIntentDiscoveryCard: View {
    @State private var isStatusTipVisible = true

    var body: some View {
        CardContainer(title: "Siri & Shortcuts", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                SiriTipView(intent: GetVehicleStatusIntent(), isVisible: $isStatusTipVisible)
                    .siriTipViewStyle(.automatic)

                HStack(spacing: 12) {
                    ShortcutsLink()
                        .shortcutsLinkStyle(.automatic)

                    Text("Manage car status, lock, unlock, climate, software, drives, horn, lights, and navigation actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

#Preview {
    AppIntentDiscoveryCard()
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}
