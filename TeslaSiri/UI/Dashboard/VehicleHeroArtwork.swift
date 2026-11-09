import AppIntents
import FleetKit
import SwiftUI

/// Static vehicle hero for the Dashboard. Uses the light/dark renders in
/// `VehicleAssets.xcassets`, which share the 1672:941 hero aspect ratio.
struct VehicleHeroArtwork: View {
    let vehicleName: String
    let vin: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(colorScheme == .dark ? "VehicleHeroDark" : "VehicleHeroLight")
            .resizable()
            .aspectRatio(1672.0 / 941.0, contentMode: .fit)
            .mask {
                // The renders carry a vignette; feather the edges so the artwork
                // dissolves into the page instead of reading as a pasted rectangle.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.14),
                            .init(color: .black, location: 0.82),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(vehicleName) vehicle")
            .appEntityIdentifier(vehicleEntityIdentifier)
    }

    private var vehicleEntityIdentifier: EntityIdentifier? {
        guard !vin.isEmpty else { return nil }
        return EntityIdentifier(for: VehicleEntity.self, identifier: vin)
    }
}

#Preview("Hero — Light") {
    VehicleHeroArtwork(vehicleName: "Model 3", vin: "5YJ3E1EA0PF000001")
        .padding()
}

#Preview("Hero — Dark") {
    VehicleHeroArtwork(vehicleName: "Model 3", vin: "5YJ3E1EA0PF000001")
        .padding()
        .preferredColorScheme(.dark)
}
