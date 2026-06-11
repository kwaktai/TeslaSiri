import SwiftUI

struct WebhooksSection: View {
    @Bindable var store: FleetNotificationWebhookStore
    let capabilities: FleetCapabilities?
    let selectedVIN: String?
    let onRequestAuthorization: () -> Void
    let onSendLocalTest: () -> Void

    var body: some View {
        CardContainer(title: "Notification Webhooks", systemImage: "bell.and.waves.left.and.right") {
            VStack(alignment: .leading, spacing: 12) {
                DiagnosticRow(label: "Authorization", value: store.authorizationStatusDescription)
                DiagnosticMonospacedValue(title: "Device ID", value: store.deviceID)
                DiagnosticRow(label: "Hooks", value: "\(store.activeWebhooks.count) active / \(store.webhooks.count) total")

                if let configuredCallbackURL = store.configuredCallbackURL {
                    DiagnosticMonospacedValue(title: "Configured URL", value: configuredCallbackURL.absoluteString)
                }

                TextField("Callback URL", text: $store.draftCallbackURLString)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                if let lastRequestID = store.lastRequestID {
                    DiagnosticMonospacedValue(title: "Hook request", value: lastRequestID)
                }

                if let lastErrorMessage = store.lastErrorMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(lastErrorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                DiagnosticRow(label: "Hook action", value: store.lastActionMessage)

                HStack(spacing: 12) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.isLoading || store.isMutating)

                    Button {
                        Task { await store.ensureWebhook(capabilities: capabilities, vins: selectedVIN.map { [$0] } ?? []) }
                    } label: {
                        Label("Ensure Hook", systemImage: "link.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.isLoading || store.isMutating)
                }

                HStack(spacing: 12) {
                    Button {
                        onRequestAuthorization()
                    } label: {
                        Label("Authorize", systemImage: "bell.badge")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        onSendLocalTest()
                    } label: {
                        Label("Local Test", systemImage: "bell.and.waves.left.and.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if !store.webhooks.isEmpty {
                    Divider()
                    VStack(spacing: 12) {
                        ForEach(store.webhooks) { webhook in
                            NotificationWebhookRow(
                                webhook: webhook,
                                isMutating: store.isMutating,
                                onToggle: {
                                    Task { await store.setWebhook(webhook, enabled: !webhook.enabled) }
                                },
                                onRefreshEvents: {
                                    Task { await store.refreshEvents(for: webhook, capabilities: capabilities) }
                                },
                                onTest: {
                                    Task { await store.testWebhook(webhook, vin: selectedVIN) }
                                },
                                onDelete: {
                                    Task { await store.deleteWebhook(webhook) }
                                }
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct DiagnosticRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview("Empty store") {
    WebhooksSection(
        store: FleetNotificationWebhookStore(),
        capabilities: FleetDataStore.previewLoaded().capabilities,
        selectedVIN: PreviewData.vin1,
        onRequestAuthorization: {},
        onSendLocalTest: {}
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}
