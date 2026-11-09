import SwiftUI

struct CachedDataCard: View {
    let cacheDate: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Showing cached data")
                    .font(.subheadline.weight(.semibold))
                if let cacheDate {
                    RelativeTimeText(date: cacheDate, style: .updated)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Live data is refreshing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(cornerRadius: 18, fill: Color.orange.opacity(0.10))
        .accessibilityElement(children: .combine)
    }
}

#Preview("With date") {
    CachedDataCard(cacheDate: Date().addingTimeInterval(-3600))
        .padding()
        .background(AppScreenBackground())
}

#Preview("Without date") {
    CachedDataCard(cacheDate: nil)
        .padding()
        .background(AppScreenBackground())
}
