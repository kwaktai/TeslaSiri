import AppIntents
import FleetKit
import SwiftUI

struct VehiclePickerCard: View {
    let vehicles: [FleetVehicle]
    let selectedVIN: String?
    let onSelect: (String) -> Void

    var body: some View {
        CardContainer(title: "Vehicles", systemImage: "car.2") {
            if vehicles.isEmpty {
                Text("No vehicles linked.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(vehicles) { vehicle in
                            Button {
                                onSelect(vehicle.vin)
                            } label: {
                                VehicleChip(
                                    name: vehicle.name,
                                    vin: vehicle.vin,
                                    batteryLevel: vehicle.latest?.batteryLevel,
                                    chargingState: vehicle.latest?.chargingState,
                                    isLocked: vehicle.latest?.locked,
                                    isSelected: selectedVIN == vehicle.vin
                                )
                            }
                            .buttonStyle(.plain)
                            .appEntityIdentifier(EntityIdentifier(for: VehicleEntity.self, identifier: vehicle.vin))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct VehicleChip: View {
    let name: String
    let vin: String
    let batteryLevel: Double?
    let chargingState: String?
    let isLocked: Bool?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "car.side")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            Text("VIN " + String(vin.suffix(6)))
                .font(.caption2)
                .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)

            HStack(spacing: 8) {
                Label {
                    Text(formattedNumber(batteryLevel, suffix: "%"))
                        .font(.caption.weight(.medium))
                } icon: {
                    Image(systemName: "battery.75")
                        .font(.caption2)
                }
                if let isLocked {
                    Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                        .font(.caption2)
                }
            }
            .foregroundStyle(isSelected ? .white : .secondary)
        }
        .padding(12)
        .frame(width: 180, alignment: .leading)
        .background(
            isSelected ? Color.accentColor : Color(uiColor: .tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .foregroundStyle(isSelected ? .white : .primary)
    }
}

#Preview("Multiple vehicles") {
    VehiclePickerCard(
        vehicles: PreviewData.vehicles,
        selectedVIN: PreviewData.vin1,
        onSelect: { _ in }
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Empty") {
    VehiclePickerCard(vehicles: [], selectedVIN: nil, onSelect: { _ in })
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Single vehicle") {
    VehiclePickerCard(
        vehicles: [PreviewData.vehicles[0]],
        selectedVIN: nil,
        onSelect: { _ in }
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}
