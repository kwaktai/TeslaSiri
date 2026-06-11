import SwiftUI

struct AccountSection: View {
    let email: String?
    let units: String?
    let scopes: [String]

    var body: some View {
        CardContainer(title: "Account", systemImage: "person.crop.circle") {
            VStack(alignment: .leading, spacing: 10) {
                if let email {
                    AccountRow(label: "Email", value: email)
                }
                if let units {
                    AccountRow(label: "Units", value: units.capitalized)
                }
                AccountRow(label: "Scopes", value: scopes.isEmpty ? "--" : scopes.sorted().joined(separator: ", "))
            }
        }
    }
}

private struct AccountRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
        }
    }
}

#Preview("Imperial") {
    AccountSection(email: PreviewData.user.email, units: PreviewData.user.units, scopes: PreviewData.user.scopes)
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Metric") {
    AccountSection(email: PreviewData.userMetric.email, units: PreviewData.userMetric.units, scopes: PreviewData.userMetric.scopes)
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}
