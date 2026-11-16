import AppIntents
import FleetKit
import SwiftUI

struct SpotlightDebugSection: View {
    let isSignedIn: Bool
    let requestedQuery: String

    @State private var query = "Tesla"
    @State private var isIndexing = false
    @State private var isSearching = false
    @State private var report: FleetSpotlightIndexingReport?
    @State private var results: [FleetSpotlightSearchResult] = []
    @State private var message = "Not run"

    var body: some View {
        CardContainer(title: "Spotlight Index", systemImage: "magnifyingglass.circle") {
            VStack(alignment: .leading, spacing: 12) {
                SpotlightDebugRow(label: "Index", value: FleetSpotlightIndexer.indexName)
                SpotlightDebugRow(label: "Status", value: message)

                if let report {
                    SpotlightDebugRow(label: "Submitted", value: "\(report.submittedCount) entities at \(report.submittedAt.formatted(date: .omitted, time: .shortened))")
                    ForEach(report.groups) { group in
                        DiagnosticMonospacedValue(title: group.name, value: groupSummary(group))
                    }
                    if !report.errors.isEmpty {
                        DiagnosticMonospacedValue(title: "Errors", value: report.errors.joined(separator: "\n"))
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await reindex() }
                    } label: {
                        if isIndexing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Reindex", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!isSignedIn || isIndexing)

                    Button {
                        Task { await search() }
                    } label: {
                        if isSearching {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Query", systemImage: "magnifyingglass")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!isSignedIn || isSearching)
                }

                TextField("Search indexed vehicle data", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        Task { await search() }
                    }
                    .disabled(!isSignedIn)

                if !results.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Results")
                            .font(.subheadline.weight(.semibold))
                        ForEach(results) { result in
                            SpotlightResultRow(result: result)
                        }
                    }
                }
            }
        }
        .task(id: automaticSearchID) {
            guard isSignedIn else {
                report = nil
                results = []
                message = "Sign in to index Fleet entities."
                return
            }

            let requestedQuery = requestedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !requestedQuery.isEmpty {
                query = requestedQuery
            }
            await search()
        }
    }

    private var automaticSearchID: String {
        "\(isSignedIn)|\(requestedQuery)"
    }

    private func reindex() async {
        guard !isIndexing else { return }
        isIndexing = true
        defer { isIndexing = false }

        let nextReport = await FleetSpotlightIndexer.reindexAll()
        report = nextReport
        message = nextReport.succeeded ? "Indexed \(nextReport.submittedCount) entities." : "Indexed with \(nextReport.errors.count) warning(s)."
        await search()
    }

    private func search() async {
        guard !isSearching else { return }
        isSearching = true
        defer { isSearching = false }

        do {
            results = try await FleetSpotlightIndexer.search(query, limit: 20)
            message = results.isEmpty ? "No matching indexed items for \"\(query)\"." : "Found \(results.count) indexed item(s)."
        } catch {
            results = []
            message = error.localizedDescription
        }
    }

    private func groupSummary(_ group: FleetSpotlightSubmittedGroup) -> String {
        guard !group.sampleTitles.isEmpty else { return "\(group.count) submitted" }
        return "\(group.count) submitted\n" + group.sampleTitles.joined(separator: "\n")
    }
}

private struct SpotlightResultRow: View {
    let result: FleetSpotlightSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.title)
                .font(.subheadline.weight(.semibold))
            if let subtitle = result.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let contentDescription = result.contentDescription, !contentDescription.isEmpty {
                Text(contentDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            if !result.keywords.isEmpty {
                Text(result.keywords.prefix(8).joined(separator: ", "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            DiagnosticMonospacedValue(title: "ID", value: result.id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .appEntityIdentifier(entityIdentifier)
    }

    private var entityIdentifier: EntityIdentifier? {
        switch result.kind {
        case "Tesla Vehicle":
            return EntityIdentifier(for: VehicleEntity.self, identifier: result.id)
        case "Tesla Vehicle Status":
            return EntityIdentifier(for: VehicleStatusEntity.self, identifier: result.id)
        case "Tesla Drive":
            return EntityIdentifier(for: DriveEntity.self, identifier: result.id)
        case "Tesla Software Update":
            return EntityIdentifier(for: SoftwareUpdateEntity.self, identifier: result.id)
        case "Tesla Release Note":
            return EntityIdentifier(for: ReleaseNoteEntity.self, identifier: result.id)
        default:
            return nil
        }
    }
}

private struct SpotlightDebugRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(label))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview {
    SpotlightDebugSection(isSignedIn: true, requestedQuery: "Tesla")
        .padding()
        .background(AppScreenBackground())
}
