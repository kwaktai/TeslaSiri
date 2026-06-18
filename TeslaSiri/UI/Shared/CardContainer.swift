import SwiftUI

struct AppScreenBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)

            LinearGradient(
                colors: [
                    Color.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.07),
                    .clear,
                    Color.green.opacity(colorScheme == .dark ? 0.035 : 0.025)
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
        }
        .ignoresSafeArea()
    }
}

struct CardContainer<Content: View>: View {
    let title: String?
    let systemImage: String?
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                HStack(spacing: 10) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 30, height: 30)
                            .background(Color.accentColor.opacity(0.12), in: Circle())
                    }

                    Text(title)
                        .font(.headline)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.92 : 0.98))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.90),
                            lineWidth: 0.75
                        )
                }
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06),
                    radius: 16,
                    y: 8
                )
        }
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
