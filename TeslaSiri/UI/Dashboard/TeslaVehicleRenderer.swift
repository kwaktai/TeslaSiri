import AppIntents
import FleetKit
import Foundation
import RealityKit
import SwiftUI
import TeslaVehicleKit
import UIKit

nonisolated enum VehicleRendererAsset: String, CaseIterable, Sendable {
    case cybertruck
    case model3Legacy = "model-3-legacy"
    case model3Refresh = "model-3-refresh-poppyseed"
    case modelSPalladium = "model-s-palladium"
    case modelXPalladium = "model-x-palladium"
    case modelYBayberry = "model-y-bayberry"
    case modelYBayberryE41 = "model-y-bayberry-e41"
    case modelYBayberryE80 = "model-y-bayberry-e80"
    case modelYLegacy = "model-y-legacy"
    case semi

    static func resolve(
        configuration: FleetVehicleConfiguration?,
        vin: String
    ) -> VehicleRendererAsset? {
        guard let carType = configuration?.carType?.lowercased() else { return nil }
        let fascia = configuration?.fasciaType?.lowercased() ?? ""
        let chassis = configuration?.chassisType?.lowercased() ?? ""
        let year = modelYear(from: vin)

        switch carType {
        case "model3":
            return fascia.contains("poppyseed") || (year ?? 0) >= 2024
                ? .model3Refresh
                : .model3Legacy
        case "modely":
            if chassis == "model_y_long_wheel_base" || fascia.contains("e80") {
                return .modelYBayberryE80
            }
            if fascia.contains("e41") {
                return .modelYBayberryE41
            }
            if fascia.contains("bayberry") || (year ?? 0) >= 2025 {
                return .modelYBayberry
            }
            return .modelYLegacy
        case "models", "models2", "lychee":
            return .modelSPalladium
        case "modelx", "tamarind":
            return .modelXPalladium
        case "semitruck", "semi":
            return .semi
        case "cybertruck":
            return .cybertruck
        default:
            return nil
        }
    }

    private static func modelYear(from vin: String) -> Int? {
        guard vin.count >= 10 else { return nil }
        let yearCode = vin[vin.index(vin.startIndex, offsetBy: 9)]
        let years: [Character: Int] = [
            "C": 2012, "D": 2013, "E": 2014, "F": 2015,
            "G": 2016, "H": 2017, "J": 2018, "K": 2019,
            "L": 2020, "M": 2021, "N": 2022, "P": 2023,
            "R": 2024, "S": 2025, "T": 2026, "V": 2027
        ]
        return years[Character(String(yearCode).uppercased())]
    }
}

nonisolated struct VehicleRenderState: Equatable, Sendable {
    let asset: VehicleRendererAsset?
    let chargePortOpen: Bool
    let chassisType: String
    let doorLeftFrontOpen: Bool
    let doorLeftRearOpen: Bool
    let doorRightFrontOpen: Bool
    let doorRightRearOpen: Bool
    let exteriorColor: String
    let fasciaType: String
    let interiorTrimType: String
    let paintOverride: String?
    let frontTrunkOpen: Bool
    let rearTrunkOpen: Bool
    let rightHandDrive: Bool
    let trimBadging: String
    let wheelType: String
    let windowLeftFrontOpen: Bool
    let windowLeftRearOpen: Bool
    let windowRightFrontOpen: Bool
    let windowRightRearOpen: Bool

    init(snapshot: FleetLatestSnapshot, vin: String) {
        let configuration = snapshot.vehicleConfiguration
        let closures = snapshot.closures
        let rightHandDrive = configuration?.rightHandDrive ?? false

        asset = VehicleRendererAsset.resolve(configuration: configuration, vin: vin)
        chargePortOpen = snapshot.chargePortDoorOpen ?? false
        chassisType = configuration?.chassisType ?? ""
        exteriorColor = configuration?.exteriorColor ?? "SilverMetallic"
        fasciaType = configuration?.fasciaType ?? ""
        interiorTrimType = configuration?.interiorTrimType ?? "AllBlack"
        paintOverride = configuration?.paintColorOverride
        frontTrunkOpen = closures?.frontTrunkOpen ?? false
        rearTrunkOpen = closures?.rearTrunkOpen ?? false
        self.rightHandDrive = rightHandDrive
        trimBadging = configuration?.trimBadging ?? ""
        wheelType = configuration?.wheelType ?? ""

        if rightHandDrive {
            doorLeftFrontOpen = closures?.frontPassengerDoorOpen ?? false
            doorLeftRearOpen = closures?.rearPassengerDoorOpen ?? false
            doorRightFrontOpen = closures?.frontDriverDoorOpen ?? false
            doorRightRearOpen = closures?.rearDriverDoorOpen ?? false
            windowLeftFrontOpen = closures?.frontPassengerWindowOpen ?? false
            windowLeftRearOpen = closures?.rearPassengerWindowOpen ?? false
            windowRightFrontOpen = closures?.frontDriverWindowOpen ?? false
            windowRightRearOpen = closures?.rearDriverWindowOpen ?? false
        } else {
            doorLeftFrontOpen = closures?.frontDriverDoorOpen ?? false
            doorLeftRearOpen = closures?.rearDriverDoorOpen ?? false
            doorRightFrontOpen = closures?.frontPassengerDoorOpen ?? false
            doorRightRearOpen = closures?.rearPassengerDoorOpen ?? false
            windowLeftFrontOpen = closures?.frontDriverWindowOpen ?? false
            windowLeftRearOpen = closures?.rearDriverWindowOpen ?? false
            windowRightFrontOpen = closures?.frontPassengerWindowOpen ?? false
            windowRightRearOpen = closures?.rearPassengerWindowOpen ?? false
        }
    }

    var teslaConfiguration: TeslaVehicleConfiguration? {
        guard let asset else { return nil }

        let vehicleID = asset.rawValue
        let profile = VehicleConfigurationCatalog.profile(for: vehicleID)
        var options = profile.defaultSelections
        options["driver"] = rightHandDrive ? "rhd" : "lhd"
        options["market"] = rightHandDrive ? "eu" : "us"

        let descriptor = Self.normalized(
            [chassisType, fasciaType, trimBadging].joined(separator: " ")
        )
        let isPerformance = descriptor.contains("performance") || descriptor.contains("perf")
        let hasSevenSeats = descriptor.contains("7seat")
            || descriptor.contains("sevenseat")
            || descriptor.contains("longwheelbase")

        switch asset {
        case .model3Legacy:
            options["trim"] = isPerformance ? "performance" : "standard"
        case .model3Refresh:
            if descriptor.contains("d50") {
                options["variant"] = "d50"
            } else {
                options["variant"] = isPerformance ? "performance" : "standard"
            }
        case .modelYLegacy:
            options["trim"] = isPerformance ? "performance" : "standard"
            options["seats"] = hasSevenSeats ? "seven" : "five"
        case .modelYBayberry:
            options["variant"] = isPerformance ? "performance" : "standard"
            options["seats"] = hasSevenSeats ? "seven" : "five"
        case .modelYBayberryE41, .modelYBayberryE80, .semi:
            break
        case .modelSPalladium:
            options["powertrain"] = Self.palladiumPowertrain(
                descriptor: descriptor,
                standardValue: "long-range"
            )
        case .modelXPalladium:
            options["powertrain"] = Self.palladiumPowertrain(
                descriptor: descriptor,
                standardValue: "standard"
            )
            if descriptor.contains("6seat") || descriptor.contains("sixseat") {
                options["seats"] = "six"
            } else {
                options["seats"] = hasSevenSeats ? "seven" : "five"
            }
        case .cybertruck:
            let isRearWheelDrive = descriptor.contains("rwd")
                || descriptor.contains("rearwheeldrive")
                || descriptor.contains("singlemotor")
            options["hardware"] = isRearWheelDrive ? "rwd" : "premium"
            options["rear-display"] = isRearWheelDrive ? "none" : "installed"
        }

        if let wheelID = resolvedWheelID {
            options["wheels"] = wheelID
        }
        if Self.normalized(interiorTrimType).contains("grey")
            || Self.normalized(interiorTrimType).contains("gray") {
            options["upper-trim"] = "grey"
        }

        return TeslaVehicleConfiguration(
            vehicleID: vehicleID,
            paintID: customPaint?.id ?? resolvedPaintID,
            interiorID: resolvedInteriorID,
            options: profile.normalizedSelections(options),
            cameraID: .parked,
            lightsOn: false,
            lightingStrength: 1.2
        )
    }

    var customPaint: PaintPreset? {
        if let paintOverride,
           let colorHex = Self.normalizedHexColor(paintOverride) {
            return PaintPreset(
                id: "TessiePaintOverride",
                colorHex: colorHex,
                metallic: 0.65,
                roughness: 0.08
            )
        }

        let key = Self.normalized(exteriorColor)
        guard let presentation = Self.presentationPaint(for: key) else { return nil }
        return PaintPreset(
            id: "Tessie-\(key)",
            colorHex: presentation.hex,
            metallic: presentation.metallic,
            roughness: presentation.roughness
        )
    }

    var openAnimation: TeslaAnimationPreset? {
        if frontTrunkOpen { return .hood }
        if rearTrunkOpen { return .trunk }
        if chargePortOpen { return .chargePort }

        let openDoors: [TeslaAnimationPreset] = [
            doorLeftFrontOpen ? .leftFrontDoor : nil,
            doorLeftRearOpen ? .leftRearDoor : nil,
            doorRightFrontOpen ? .rightFrontDoor : nil,
            doorRightRearOpen ? .rightRearDoor : nil
        ].compactMap { $0 }
        if openDoors.count > 1 { return .allDoors }
        if let openDoor = openDoors.first { return openDoor }

        let openWindows: [TeslaAnimationPreset] = [
            windowLeftFrontOpen ? .leftFrontWindow : nil,
            windowLeftRearOpen ? .leftRearWindow : nil,
            windowRightFrontOpen ? .rightFrontWindow : nil,
            windowRightRearOpen ? .rightRearWindow : nil
        ].compactMap { $0 }
        if openWindows.count > 1 { return .allWindows }
        return openWindows.first
    }

    private var resolvedPaintID: String {
        if customPaint != nil { return "TessiePaintOverride" }
        let key = Self.normalized(exteriorColor)
        switch key {
        case "redmulticoat", "redmulticoatpaint": return "RedMulticoat"
        case "solidblack": return "SolidBlack"
        case "silvermetallic": return "SilverMetallic"
        case "midnightsilver", "midnightsilvermetallic": return "MidnightSilver"
        case "deepblue", "deepbluemetallic": return "DeepBlue"
        case "pearlwhite", "pearlwhitemulticoat": return "PearlWhite"
        case "titaniumcopper": return "TitaniumCopper"
        case "red": return "Red"
        case "black": return "Black"
        case "silver": return "Silver"
        case "grey", "gray": return "Grey"
        case "signatureblue": return "SignatureBlue"
        case "white": return "White"
        case "titanium": return "Titanium"
        case "pearl": return "Pearl"
        case "metallicblack": return "MetallicBlack"
        case "steelgrey", "steelgray": return "SteelGrey"
        case "green": return "Green"
        case "brown": return "Brown"
        case "sigred", "signaturered": return "SigRed"
        case "blue": return "Blue"
        case "midnightcherryred": return "MidnightCherryRed"
        case "quicksilver": return "Quicksilver"
        case "ultrared": return "UltraRed"
        case "stealthgrey", "stealthgray": return "StealthGrey"
        case "lunarsilver": return "LunarSilver"
        case "glacierblue": return "GlacierBlue"
        case "diamondblack": return "DiamondBlack"
        case "frostblue": return "FrostBlue"
        case "silkroadsilver": return "SilkroadSilver"
        case "marineblue": return "MarineBlue"
        case "garnetred": return "GarnetRed"
        case "stainlesssteel": return "StainlessSteel"
        default:
            return asset == .cybertruck ? "StainlessSteel" : "PearlWhite"
        }
    }

    private var resolvedInteriorID: String {
        let key = Self.normalized(interiorTrimType)
        if key.contains("white") {
            return InteriorPreset.white.id
        }
        if key.contains("cream") || key.contains("walnut")
            || key.contains("tan") || key.contains("beige") {
            return InteriorPreset.cream.id
        }
        if key.contains("tacticalgrey") || key.contains("tacticalgray") {
            return InteriorPreset.tacticalGray.id
        }
        if key.contains("textile") || key.contains("fabric") {
            return InteriorPreset.textile.id
        }
        return InteriorPreset.black.id
    }

    private var resolvedWheelID: String? {
        let key = Self.normalized(wheelType)
        guard !key.isEmpty else { return nil }

        if key.contains("ctpremium") { return "ct-premium20" }
        if key.contains("ctbase18") { return "ct-base18" }
        if key.contains("ctbase20") { return "ct-base20" }
        if key.contains("arachnidv2") { return "arachnid-v2-21" }
        if key.contains("machinav2") { return "machina-v2-19" }
        if key.contains("helixv2") {
            return key.contains("dark") ? "helix-v2-dark-20" : "helix-v2-20"
        }
        if key.contains("apollo19metallicshadow") { return "apollo-shadow19" }
        if key.contains("wishbone20") { return "wishbone20" }
        if key.contains("wishbone19") { return "wishbone19" }
        if key.contains("crossflow") { return "crossflow19" }
        if key.contains("d5018") { return "d50-18" }
        if key.contains("e4118") { return "e41-18" }
        if key.contains("glider") { return "glider" }
        if key.contains("helix19") { return "helix19" }
        if key.contains("induction") { return "induction20" }
        if key.contains("pinwheel") { return "pinwheel" }
        if key.contains("stiletto") { return "stiletto19" }
        if key.contains("uberturbine") { return "uberturbine" }
        if key.contains("zerog") { return "zero-g" }
        if key.contains("gemini") || key == "apollo19" { return "gemini" }
        if key.contains("newturbine22") || key.contains("turbine22") {
            return "new-turbine22"
        }
        if key.contains("halo22") { return "halo22" }
        if key.contains("riptide20") { return "riptide20" }
        if key.contains("cypress21") { return "cypress21" }
        if key.contains("cyberstream20") || key.contains("slipstream20")
            || key.contains("aeroturbine20") {
            return "cyberstream20"
        }
        if key.contains("cardenio19") || key.contains("tempest19")
            || key.contains("turbine19") {
            return "cardenio19"
        }
        if key.contains("arachnid21") { return "arachnid21" }
        if key.contains("standard19") || key.contains("base19") {
            return "standard19"
        }
        return nil
    }

    private static func palladiumPowertrain(
        descriptor: String,
        standardValue: String
    ) -> String {
        if descriptor.contains("signature") { return "signature" }
        if descriptor.contains("plaid") || descriptor.contains("performance") {
            return "plaid"
        }
        return standardValue
    }

    private static func presentationPaint(
        for key: String
    ) -> (hex: String, metallic: Double, roughness: Double)? {
        switch key {
        case "redmulticoat", "redmulticoatpaint": ("#9C0713", 0.12, 0.18)
        case "ultrared": ("#A3050C", 0.18, 0.2)
        case "garnetred": ("#6D0714", 0.8, 0.08)
        case "midnightcherryred": ("#4D0717", 0.8, 0.06)
        case "sigred", "signaturered": ("#7F0612", 0.7, 0.08)
        case "solidblack", "black", "metallicblack", "diamondblack":
            ("#0E0E0E", 0.8, 0.08)
        case "silvermetallic", "silver": ("#9298A1", 0.6, 0.14)
        case "midnightsilver", "midnightsilvermetallic": ("#414751", 0.8, 0.1)
        case "stealthgrey", "stealthgray": ("#30343A", 0.88, 0.12)
        case "steelgrey", "steelgray", "grey", "gray": ("#4A4F56", 0.8, 0.1)
        case "deepblue", "deepbluemetallic": ("#12305F", 0.7, 0.1)
        case "signatureblue": ("#14264A", 0.3, 0.1)
        case "glacierblue": ("#6B91BD", 0.7, 0.14)
        case "frostblue": ("#7896AD", 0.72, 0.1)
        case "marineblue", "blue": ("#062C49", 0.75, 0.1)
        case "pearlwhite", "pearlwhitemulticoat", "white", "pearl":
            ("#E1E0DB", 0.25, 0.22)
        case "quicksilver": ("#818791", 0.85, 0.2)
        case "lunarsilver": ("#9AA0AA", 0.9, 0.28)
        case "silkroadsilver": ("#8E8884", 0.83, 0.2)
        case "titanium", "titaniumcopper": ("#6E5942", 0.8, 0.12)
        case "green": ("#1F403E", 0.8, 0.1)
        case "brown": ("#5E3A2E", 0.8, 0.1)
        default: nil
        }
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func normalizedHexColor(_ value: String) -> String? {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.lowercased().hasPrefix("0x") {
            candidate.removeFirst(2)
        }
        if candidate.hasPrefix("#") {
            candidate.removeFirst()
        }
        guard candidate.count == 6 || candidate.count == 8,
              candidate.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return "#\(candidate.uppercased())"
    }
}

struct VehicleHeroArtwork: View {
    let vehicleName: String
    let vin: String
    let renderState: VehicleRenderState

    var body: some View {
        VehicleHeroRenderSurface(renderState: renderState)
            .aspectRatio(1672.0 / 941.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(vehicleName) vehicle")
            .appEntityIdentifier(vehicleEntityIdentifier)
    }

    private var vehicleEntityIdentifier: EntityIdentifier? {
        guard !vin.isEmpty else { return nil }
        return EntityIdentifier(for: VehicleEntity.self, identifier: vin)
    }
}

private struct VehicleHeroRenderSurface: View {
    let renderState: VehicleRenderState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var session: TeslaVehicleSession

    init(renderState: VehicleRenderState) {
        self.renderState = renderState
        let session = TeslaVehicleSession(
            configuration: renderState.teslaConfiguration
                ?? TeslaVehicleConfiguration.factoryDefault(for: "model-y-bayberry")
        )
        if let customPaint = renderState.customPaint {
            session.setCustomPaint(customPaint)
        }
        _session = StateObject(wrappedValue: session)
    }

    var body: some View {
        ZStack {
            VehicleHeroFallback(imageName: fallbackImageName)
                .opacity(isRendererReady ? 0 : 1)

            if renderState.asset != nil {
                TeslaVehicleView(
                    session: session,
                    allowsCameraInteraction: false,
                    showsGroundShadow: false,
                    configureARView: configureARView
                )
                .id(colorScheme)
                .allowsHitTesting(false)
                .opacity(isRendererReady ? 1 : 0)
            }
        }
        .background(stageColor)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: isRendererReady)
        .onAppear {
            synchronizeSession()
        }
        .onChange(of: renderState) {
            synchronizeSession()
        }
        .onChange(of: reduceMotion) {
            synchronizeSession()
        }
    }

    private var isRendererReady: Bool {
        if case .ready = session.renderState {
            return true
        }
        return false
    }

    private var fallbackImageName: String {
        colorScheme == .dark ? "VehicleHeroDark" : "VehicleHeroLight"
    }

    private var stageColor: Color {
        colorScheme == .dark
            ? Color(red: 0.018, green: 0.015, blue: 0.016)
            : Color(red: 0.982, green: 0.974, blue: 0.968)
    }

    private var stageUIColor: UIColor {
        colorScheme == .dark
            ? UIColor(red: 0.018, green: 0.015, blue: 0.016, alpha: 1)
            : UIColor(red: 0.982, green: 0.974, blue: 0.968, alpha: 1)
    }

    private func synchronizeSession() {
        guard let configuration = renderState.teslaConfiguration else {
            session.stopAnimation()
            return
        }

        session.apply(configuration)
        if let customPaint = renderState.customPaint {
            session.setCustomPaint(customPaint)
        }
        applyHeroCamera()

        if reduceMotion {
            session.stopAnimation()
        } else if let animation = renderState.openAnimation {
            session.play(animation, direction: .open, loop: false)
        } else {
            session.play(.turntable, loop: true)
        }
    }

    private func applyHeroCamera() {
        guard let camera = session.cameraPresets.first(where: {
            $0.id == TeslaCameraViewID.parked.rawValue
        }) else { return }

        session.setCustomCamera(
            CameraPreset(
                id: "TESLA_SIRI_HERO",
                rotation: camera.rotation,
                offset: camera.offset.map { $0 * 0.72 },
                fov: camera.fov,
                environmentAsset: camera.environmentAsset,
                environmentRotation: camera.environmentRotation,
                environmentEnergy: camera.environmentEnergy,
                ambientEnergy: camera.ambientEnergy,
                rotatesSkybox: camera.rotatesSkybox
            )
        )
    }

    private func configureARView(_ view: ARView) {
        let background = stageUIColor
        view.isOpaque = true
        view.backgroundColor = background
        view.layer.backgroundColor = background.cgColor
        var environment = view.environment
        environment.background = .color(background)
        view.environment = environment
    }
}

private struct VehicleHeroFallback: View {
    let imageName: String

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
    }
}
