import SwiftUI

struct DiagnosticMonospacedValue: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(title)
        }
    }
}

#Preview {
    CardContainer(title: "Diagnostics") {
        VStack(spacing: 0) {
            DiagnosticMonospacedValue(title: "Device ID", value: "device-abc-123")
            DiagnosticMonospacedValue(title: "Request ID", value: "req_8f3a1b2c4d5e6f7g")
            DiagnosticMonospacedValue(title: "Cursor", value: "1781000000000")
            DiagnosticMonospacedValue(title: "Long URL", value: "https://fleet.maxweinbach.com/api/v1/webhooks/device-abc-123/callback")
        }
    }
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}
