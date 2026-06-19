import Foundation
import Observation
import TeslaVehicleKit

struct RendererSceneTuning: Codable, Equatable, Sendable {
    var cameraRotationX: Double
    var cameraRotationY: Double
    var cameraRotationZ: Double
    var cameraOffsetX: Double
    var cameraOffsetY: Double
    var cameraOffsetZ: Double
    var fieldOfView: Double
    var environmentAsset: String
    var environmentRotationX: Double
    var environmentRotationY: Double
    var environmentRotationZ: Double
    var environmentEnergy: Double
    var ambientEnergy: Double
    var lightingStrength: Double
    var viewportScale: Double
    var viewportOffsetX: Double
    var viewportOffsetY: Double
    var rotatesSkybox: Bool
    var showsGroundShadow: Bool
    var animationEnabled: Bool

    init(camera: CameraPreset, cameraDistanceScale: Double = 0.72) {
        cameraRotationX = camera.rotation[safe: 0] ?? 0
        cameraRotationY = camera.rotation[safe: 1] ?? 0
        cameraRotationZ = camera.rotation[safe: 2] ?? 0
        cameraOffsetX = (camera.offset[safe: 0] ?? 0) * cameraDistanceScale
        cameraOffsetY = (camera.offset[safe: 1] ?? 0) * cameraDistanceScale
        cameraOffsetZ = (camera.offset[safe: 2] ?? 0) * cameraDistanceScale
        fieldOfView = camera.fov
        environmentAsset = camera.environmentAsset
        environmentRotationX = camera.environmentRotation[safe: 0] ?? 0
        environmentRotationY = camera.environmentRotation[safe: 1] ?? 0
        environmentRotationZ = camera.environmentRotation[safe: 2] ?? 0
        environmentEnergy = camera.environmentEnergy
        ambientEnergy = camera.ambientEnergy
        lightingStrength = 1.2
        viewportScale = 1
        viewportOffsetX = 0
        viewportOffsetY = 0
        rotatesSkybox = camera.rotatesSkybox
        showsGroundShadow = false
        animationEnabled = true
    }

    func cameraPreset(sceneID: String) -> CameraPreset {
        CameraPreset(
            id: "TESLA_SIRI_DEBUG_\(sceneID)",
            rotation: [cameraRotationX, cameraRotationY, cameraRotationZ],
            offset: [cameraOffsetX, cameraOffsetY, cameraOffsetZ],
            fov: fieldOfView,
            environmentAsset: environmentAsset,
            environmentRotation: [
                environmentRotationX,
                environmentRotationY,
                environmentRotationZ
            ],
            environmentEnergy: environmentEnergy,
            ambientEnergy: ambientEnergy,
            rotatesSkybox: rotatesSkybox
        )
    }

    static let fallback = RendererSceneTuning(
        camera: CameraPreset(
            id: TeslaCameraViewID.parked.rawValue,
            rotation: [68.6, -138, 0],
            offset: [-0.06, 6.7, 0],
            fov: 40,
            environmentAsset: "New_Studio",
            environmentRotation: [0, -11, 83],
            environmentEnergy: 6,
            ambientEnergy: 2.6,
            rotatesSkybox: false
        )
    )
}

@MainActor
@Observable
final class VehicleRendererDebugSettings {
    var selectedSceneID = TeslaCameraViewID.parked.rawValue {
        didSet {
            guard selectedSceneID != oldValue else { return }
            applyActiveProfile()
            persist()
        }
    }

    var tuning = RendererSceneTuning.fallback {
        didSet {
            guard isReady, !isApplyingProfile, tuning != oldValue else { return }
            overrides[activeProfileKey] = tuning
            persist()
        }
    }

    private(set) var activeVehicleID = ""
    private(set) var environmentOptions = ["New_Studio"]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var factoryProfiles: [String: RendererSceneTuning] = [:]
    @ObservationIgnored private var overrides: [String: RendererSceneTuning] = [:]
    @ObservationIgnored private var isApplyingProfile = false
    @ObservationIgnored private var isReady = false

    private static let storageKey = "VehicleRendererDebugSettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedScene: TeslaCameraViewID {
        TeslaCameraViewID(rawValue: selectedSceneID) ?? .parked
    }

    var selectedSceneTitle: LocalizedStringResource {
        selectedScene.debugTitle
    }

    var exportedVariables: String {
        let value = tuning
        return """
        vehicle: \(activeVehicleID.isEmpty ? "unresolved" : activeVehicleID)
        scene: \(selectedSceneID)

        CameraPreset(
            id: "\(selectedSceneID)",
            rotation: [\(format(value.cameraRotationX)), \(format(value.cameraRotationY)), \(format(value.cameraRotationZ))],
            offset: [\(format(value.cameraOffsetX)), \(format(value.cameraOffsetY)), \(format(value.cameraOffsetZ))],
            fov: \(format(value.fieldOfView)),
            environmentAsset: "\(value.environmentAsset)",
            environmentRotation: [\(format(value.environmentRotationX)), \(format(value.environmentRotationY)), \(format(value.environmentRotationZ))],
            environmentEnergy: \(format(value.environmentEnergy)),
            ambientEnergy: \(format(value.ambientEnergy)),
            rotatesSkybox: \(value.rotatesSkybox)
        )

        lightingStrength: \(format(value.lightingStrength))
        viewportScale: \(format(value.viewportScale))
        viewportOffset: [\(format(value.viewportOffsetX)), \(format(value.viewportOffsetY))]
        showsGroundShadow: \(value.showsGroundShadow)
        animationEnabled: \(value.animationEnabled)
        """
    }

    func activate(vehicleID: String, cameraPresets: [CameraPreset]) {
        loadPersistedSettingsIfNeeded()

        let normalizedVehicleID = vehicleID.isEmpty ? "generic" : vehicleID
        let sceneCameras = cameraPresets.filter { TeslaCameraViewID(rawValue: $0.id) != nil }
        let environmentNames = Set(sceneCameras.map(\.environmentAsset))
        let newEnvironmentOptions = environmentNames.sorted()
        if !newEnvironmentOptions.isEmpty, newEnvironmentOptions != environmentOptions {
            environmentOptions = newEnvironmentOptions
        }

        for camera in sceneCameras {
            factoryProfiles[profileKey(vehicleID: normalizedVehicleID, sceneID: camera.id)] =
                RendererSceneTuning(camera: camera)
        }

        guard activeVehicleID != normalizedVehicleID || !isReady else { return }
        activeVehicleID = normalizedVehicleID
        isReady = true
        applyActiveProfile()
    }

    func resetSelectedScene() {
        overrides.removeValue(forKey: activeProfileKey)
        applyActiveProfile()
        persist()
    }

    func resetAllScenesForActiveVehicle() {
        let prefix = "\(activeVehicleID)::"
        overrides = overrides.filter { !$0.key.hasPrefix(prefix) }
        applyActiveProfile()
        persist()
    }

    private var activeProfileKey: String {
        profileKey(vehicleID: activeVehicleID.isEmpty ? "generic" : activeVehicleID, sceneID: selectedSceneID)
    }

    private func profileKey(vehicleID: String, sceneID: String) -> String {
        "\(vehicleID)::\(sceneID)"
    }

    private func applyActiveProfile() {
        guard isReady else { return }
        isApplyingProfile = true
        tuning = overrides[activeProfileKey]
            ?? factoryProfiles[activeProfileKey]
            ?? RendererSceneTuning.fallback
        isApplyingProfile = false
    }

    private func loadPersistedSettingsIfNeeded() {
        guard !isReady,
              let data = defaults.data(forKey: Self.storageKey),
              let payload = try? JSONDecoder().decode(PersistedRendererSettings.self, from: data)
        else { return }

        selectedSceneID = TeslaCameraViewID(rawValue: payload.selectedSceneID)?.rawValue
            ?? TeslaCameraViewID.parked.rawValue
        overrides = payload.overrides
    }

    private func persist() {
        guard isReady else { return }
        let payload = PersistedRendererSettings(
            selectedSceneID: selectedSceneID,
            overrides: overrides
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func format(_ value: Double) -> String {
        value.formatted(
            .number
                .locale(Locale(identifier: "en_US_POSIX"))
                .precision(.fractionLength(3))
                .grouping(.never)
        )
    }
}

private struct PersistedRendererSettings: Codable {
    let selectedSceneID: String
    let overrides: [String: RendererSceneTuning]
}

extension TeslaCameraViewID {
    var debugTitle: LocalizedStringResource {
        switch self {
        case .parked: "Parked"
        case .charging: "Charging"
        case .closureOpen: "Closure Open"
        case .topDown: "Top Down"
        case .climate: "Climate"
        case .drive: "Drive"
        case .driveReverse: "Drive Reverse"
        case .tentMode: "Tent Mode"
        case .vehicleToHome: "Vehicle to Home"
        case .energy: "Energy"
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
