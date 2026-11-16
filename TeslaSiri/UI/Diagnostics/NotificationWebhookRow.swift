import SwiftUI

struct NotificationWebhookRow: View {
    let webhook: FleetDeviceNotificationWebhook
    let isMutating: Bool
    let onToggle: () -> Void
    let onRefreshEvents: () -> Void
    let onTest: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Image(systemName: webhook.enabled ? "bell.badge.fill" : "bell.slash")
                        .foregroundStyle(webhook.enabled ? .green : .secondary)
                    Text(webhook.enabled ? "Enabled" : "Disabled")
                        .font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 12)
                Text(webhook.updatedAtDate, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(webhook.url.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            Text(webhook.events.isEmpty ? "No events" : webhook.events.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !webhook.vins.isEmpty {
                Text(WattieCopy.text("VINs ", "VIN ") + webhook.vins.map { String($0.suffix(6)) }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(webhook.enabled ? "Disable" : "Enable", action: onToggle)
                Button("Events", action: onRefreshEvents)
                Button("Test", action: onTest)
                Button("Delete", role: .destructive, action: onDelete)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(isMutating)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

#Preview("Enabled") {
    NotificationWebhookRow(
        webhook: PreviewData.webhookEnabled,
        isMutating: false,
        onToggle: {},
        onRefreshEvents: {},
        onTest: {},
        onDelete: {}
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Disabled - with failures") {
    NotificationWebhookRow(
        webhook: PreviewData.webhookDisabled,
        isMutating: false,
        onToggle: {},
        onRefreshEvents: {},
        onTest: {},
        onDelete: {}
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}
