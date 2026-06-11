import SwiftUI

struct CachedDataCard: View {
    let cacheDate: Date?

    var body: some View {
        CardContainer(title: "Cached data", systemImage: "clock.arrow.circlepath") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.orange)
                if let cacheDate {
                    Text("Showing cached data from \(cacheDate.formatted(date: .abbreviated, time: .shortened)).")
                } else {
                    Text("Showing cached data while live data is being refreshed.")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview("With date") {
    CachedDataCard(cacheDate: Date().addingTimeInterval(-3600))
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Without date") {
    CachedDataCard(cacheDate: nil)
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}
