import SwiftUI

/// At-a-glance card used on the Vehicle tab: a quiet symbol + title header (in the style of
/// Weather and Health), an optional trailing accessory, and free-form content below.
struct DashboardCard<Content: View, Accessory: View>: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(
        _ title: String,
        systemImage: String,
        tint: Color = .secondary,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DashboardCardHeader(title: title, systemImage: systemImage, tint: tint)
                Spacer(minLength: 8)
                accessory
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .appSurface(cornerRadius: AppTheme.cardCornerRadius)
    }
}

extension DashboardCard where Accessory == EmptyView {
    init(
        _ title: String,
        systemImage: String,
        tint: Color = .secondary,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title, systemImage: systemImage, tint: tint, accessory: { EmptyView() }, content: content)
    }
}

/// Small symbol + title header shared by dashboard cards and `CardContainer`.
struct DashboardCardHeader: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .font(.footnote.weight(.semibold))
        .labelStyle(.titleAndIcon)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Large rounded numeral with a smaller trailing unit, used for headline metrics.
struct MetricValueText: View {
    let value: String
    var unit: String? = nil
    var font: Font = .system(.largeTitle, design: .rounded, weight: .semibold)
    var unitFont: Font = .headline

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(font)
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit, !unit.isEmpty {
                Text(unit)
                    .font(unitFont)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// Plain-styled navigation row with a trailing chevron, for links inside dashboard cards.
struct DashboardCardLinkLabel: View {
    let title: String
    let systemImage: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .contentShape(.rect)
    }
}
