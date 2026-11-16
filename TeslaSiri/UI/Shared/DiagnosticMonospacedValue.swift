import SwiftUI

struct DiagnosticMonospacedValue: View {
    let title: String
    let value: String

    var body: some View {
        // Short values sit on the trailing edge; long ones (scopes, URLs, paths) wrap below the label.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                titleText
                Spacer(minLength: 8)
                valueText
                    .lineLimit(1)
                    .fixedSize()
            }

            VStack(alignment: .leading, spacing: 4) {
                titleText
                valueText
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(LocalizedStringKey(title))
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var valueText: some View {
        Text(value)
            .font(.footnote.monospaced())
            .textSelection(.enabled)
    }
}

/// Small uppercase-free group label used to split long diagnostic cards into scannable sections.
struct DiagnosticGroupHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(LocalizedStringKey(title))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

#Preview {
    CardContainer(title: "Diagnostics") {
        VStack(alignment: .leading, spacing: 12) {
            DiagnosticGroupHeader("Connection")
            DiagnosticMonospacedValue(title: "Device ID", value: "device-abc-123")
            DiagnosticMonospacedValue(title: "Request ID", value: "req_8f3a1b2c4d5e6f7g")
            DiagnosticMonospacedValue(title: "Cursor", value: "1781000000000")
            DiagnosticMonospacedValue(title: "Long URL", value: "https://api.tessie.com/vehicles")
        }
    }
    .padding()
    .background(AppScreenBackground())
}
