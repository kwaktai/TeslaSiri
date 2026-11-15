import AppIntents
import FleetKit
import SwiftUI

/// Static vehicle hero for the Vehicle tab. Uses the light/dark renders in
/// `VehicleAssets.xcassets` (1672:941). The render is cropped to a wide stage and zoomed
/// toward the car, and its edges dissolve into `AppTheme.pageBackground`, which matches
/// the render's studio backdrop, so the car reads as sitting directly on the page.
struct VehicleHeroArtwork: View {
    let vehicleName: String
    let vin: String
    /// Width-to-height ratio of the visible stage.
    var stageAspectRatio: CGFloat = 1.9

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.clear
            .aspectRatio(stageAspectRatio, contentMode: .fit)
            .overlay {
                Image(colorScheme == .dark ? "VehicleHeroDark" : "VehicleHeroLight")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(1.22, anchor: UnitPoint(x: 0.49, y: 0.6))
            }
            .clipped()
            .mask(Self.edgeFade)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(vehicleName) vehicle")
            .accessibilityAddTraits(.isImage)
            .appEntityIdentifier(vehicleEntityIdentifier)
    }

    private static var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.06),
                .init(color: .black, location: 0.94),
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
                    .init(color: .black, location: 0.8),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var vehicleEntityIdentifier: EntityIdentifier? {
        guard !vin.isEmpty else { return nil }
        return EntityIdentifier(for: VehicleEntity.self, identifier: vin)
    }
}
