import SwiftUI

struct DriveRoutePositionScrubber: View {
    let sampleCount: Int
    @Binding var selectedSampleIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Route Position", systemImage: "mappin.and.ellipse")
                    .font(.headline)
                Spacer()
                Text(formattedProgress(index: selectedSampleIndex, count: sampleCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(min(selectedSampleIndex, max(sampleCount - 1, 0))) },
                    set: { selectedSampleIndex = min(max(Int($0.rounded()), 0), max(sampleCount - 1, 0)) }
                ),
                in: 0...Double(max(sampleCount - 1, 0)),
                step: 1
            )
            .disabled(sampleCount < 2)
        }
    }

    private func formattedProgress(index: Int, count: Int) -> String {
        guard count > 1 else {
            return "--"
        }
        let percent = Double(index) / Double(count - 1) * 100
        return percent.formatted(.number.precision(.fractionLength(0))) + "%"
    }
}

struct DriveRoutePositionSummary: View {
    let point: FleetRoutePoint
    let index: Int
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Selected Position", systemImage: "scope")
                .font(.headline)
            LabeledContent("Speed", value: formattedNumber(point.speed, fractionLength: 0, suffix: " mph"))
            LabeledContent("Progress", value: formattedProgress(index: index, count: count))
        }
        .padding(.vertical, 4)
    }

    private func formattedProgress(index: Int, count: Int) -> String {
        guard count > 1 else {
            return "--"
        }
        let percent = Double(index) / Double(count - 1) * 100
        return percent.formatted(.number.precision(.fractionLength(0))) + "%"
    }
}

#Preview("Scrubber") {
    @Previewable @State var index = 3
    return CardContainer(title: "Route Position", systemImage: "mappin.and.ellipse") {
        DriveRoutePositionScrubber(sampleCount: 20, selectedSampleIndex: $index)
    }
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Summary") {
    DriveRoutePositionSummary(
        point: PreviewData.previewRoute[3],
        index: 3,
        count: PreviewData.previewRoute.count
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}
