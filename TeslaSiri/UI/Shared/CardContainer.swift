import SwiftUI

struct AppScreenBackground: View {
    var body: some View {
        AppTheme.pageBackground
            .ignoresSafeArea()
    }
}

struct CardContainer<Content: View>: View {
    let title: String?
    let systemImage: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                if let systemImage {
                    DashboardCardHeader(title: title, systemImage: systemImage, tint: .accentColor)
                } else {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .appSurface()
    }
}

struct StatusBadge: View {
    let text: String
    let systemImage: String?
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    init(_ text: String, systemImage: String? = nil, tint: Color = .secondary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(colorScheme == .dark ? 0.20 : 0.12), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.28 : 0.16), lineWidth: 0.5)
        }
        .foregroundStyle(tint)
    }
}

struct LoadingRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(label)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Card") {
    ZStack {
        AppScreenBackground()

        ScrollView {
            CardContainer(title: "Vehicle status", systemImage: "car.side.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Everything is looking good.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    StatusBadge("Connected", systemImage: "checkmark.circle.fill", tint: .green)
                }
            }
            .padding()
        }
    }
}

#Preview("Card - no header") {
    ZStack {
        AppScreenBackground()

        CardContainer {
            Text("Content without a header")
        }
        .padding()
    }
}

#Preview("Status badges") {
    ZStack {
        AppScreenBackground()

        HStack {
            StatusBadge("Charging", systemImage: "bolt.fill", tint: .orange)
            StatusBadge("Locked", systemImage: "lock.fill", tint: .green)
        }
        .padding()
    }
}

#Preview("Loading row") {
    ZStack {
        AppScreenBackground()

        CardContainer {
            LoadingRow(label: "Loading fleet data…")
        }
        .padding()
    }
}
