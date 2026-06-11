import SwiftUI

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
                HStack(spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.tint)
                    }
                    Text(title)
                        .font(.headline)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct StatusBadge: View {
    let text: String
    let systemImage: String?
    let tint: Color

    init(_ text: String, systemImage: String? = nil, tint: Color = .secondary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.15), in: Capsule())
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
    ScrollView {
        CardContainer(title: "Card title", systemImage: "car.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Body content goes here. Cards are full-width with rounded corners, a tinted title row, and 16pt padding.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Action") {}
                    .buttonStyle(.borderedProminent)
            }
        }
    }
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Card - no header") {
    CardContainer {
        Text("Plain card with no header.")
            .font(.subheadline)
    }
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Status badges") {
    VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
            StatusBadge("Charging", systemImage: "bolt.fill", tint: .orange)
            StatusBadge("Locked", systemImage: "lock.fill", tint: .green)
            StatusBadge("Sentry", systemImage: "shield.lefthalf.filled", tint: .blue)
        }
        HStack(spacing: 8) {
            StatusBadge("Unlocked", systemImage: "lock.open.fill", tint: .secondary)
            StatusBadge("Available", systemImage: "arrow.down.app", tint: .blue)
            StatusBadge("Active", systemImage: "play.fill", tint: .green)
        }
        HStack(spacing: 8) {
            StatusBadge("Plain")
            StatusBadge("No icon", tint: .purple)
        }
    }
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Loading row") {
    CardContainer(title: "Loading") {
        LoadingRow(label: "Loading software…")
    }
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}
