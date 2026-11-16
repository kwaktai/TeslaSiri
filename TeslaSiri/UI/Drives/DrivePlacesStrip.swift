import SwiftUI

/// Frequent destinations as a row of chips (icon, name, visit count). Selecting a place
/// filters the drives to that place; selecting it again clears the filter.
struct DrivePlacesStrip: View {
    let places: [DrivePlace]
    let isIndexing: Bool
    @Binding var selectedPlaceID: String?
    let onEditNickname: (DrivePlace) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Places")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if isIndexing {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Finding places")
                }
                Spacer()
                if selectedPlaceID != nil {
                    Button("Show All") {
                        selectedPlaceID = nil
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }

            if places.isEmpty {
                Text(isIndexing ? "Finding the places you drive to…" : "No places found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(places) { place in
                            PlaceChip(
                                place: place,
                                isSelected: place.id == selectedPlaceID,
                                onEditNickname: { onEditNickname(place) }
                            ) {
                                selectedPlaceID = place.id == selectedPlaceID ? nil : place.id
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
        .animation(.snappy, value: selectedPlaceID)
    }
}

private struct PlaceChip: View {
    let place: DrivePlace
    let isSelected: Bool
    let onEditNickname: () -> Void
    let onSelect: () -> Void

    var body: some View {
        Menu {
            Button("Edit Nickname", systemImage: "pencil", action: onEditNickname)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: place.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(place.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(place.visitCount == 1
                        ? WattieCopy.text("1 visit", "1회")
                        : WattieCopy.text("\(place.visitCount) visits", "\(place.visitCount)회"))
                        .font(.caption)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                Capsule()
                    .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(AppTheme.surface))
            }
            .overlay {
                Capsule()
                    .strokeBorder(isSelected ? .clear : AppTheme.hairline, lineWidth: 0.75)
            }
            .contentShape(.capsule)
        } primaryAction: {
            onSelect()
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel(place.displayName)
        .accessibilityValue(place.visitCount == 1 ? "1 visit" : "\(place.visitCount) visits")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Edit Nickname", onEditNickname)
    }
}
