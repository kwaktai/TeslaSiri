import AppIntents
import FleetKit
import SwiftUI
import TeslaVehicleKit
import UIKit

struct VehicleRendererDebugSection: View {
    let store: FleetDataStore

    @Environment(VehicleRendererDebugSettings.self) private var settings

    var body: some View {
        CardContainer(title: "Vehicle renderer", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 18) {
                RendererScenePicker(settings: settings)

                RendererDebugVehiclePreview(vehicle: store.selectedVehicle)

                RendererCompositionControls(settings: settings)
                Divider()
                RendererCameraControls(settings: settings)
                Divider()
                RendererLightingControls(settings: settings)
                Divider()
                RendererVariableReadout(settings: settings)
            }
        }
        .appEntityIdentifier(selectedVehicleEntityIdentifier)
    }

    private var selectedVehicleEntityIdentifier: EntityIdentifier? {
        guard let vin = store.selectedVehicle?.vin, !vin.isEmpty else { return nil }
        return EntityIdentifier(for: VehicleEntity.self, identifier: vin)
    }
}

private struct RendererScenePicker: View {
    @Bindable var settings: VehicleRendererDebugSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Scene") {
                Picker("Scene", selection: $settings.selectedSceneID) {
                    ForEach(TeslaCameraViewID.allCases) { scene in
                        Text(scene.debugTitle).tag(scene.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            HStack(spacing: 6) {
                Image(systemName: "car.side")
                Text(verbatim: settings.activeVehicleID.isEmpty ? "Waiting for renderer" : settings.activeVehicleID)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct RendererDebugVehiclePreview: View {
    let vehicle: FleetVehicle?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(stageColor)

            if let vehicle, let snapshot = vehicle.latest {
                VehicleHeroArtwork(
                    vehicleName: vehicle.name,
                    vin: vehicle.vin,
                    renderState: VehicleRenderState(snapshot: snapshot, vin: vehicle.vin)
                )
            } else {
                ContentUnavailableView(
                    "No render data",
                    systemImage: "cube.transparent",
                    description: Text("Load a vehicle before tuning its scene.")
                )
                .frame(minHeight: 180)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        }
    }

    private var stageColor: Color {
        colorScheme == .dark
            ? Color(red: 0.018, green: 0.015, blue: 0.016)
            : Color(red: 0.982, green: 0.974, blue: 0.968)
    }
}

private struct RendererCompositionControls: View {
    @Bindable var settings: VehicleRendererDebugSettings
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup("Composition", isExpanded: $isExpanded) {
            VStack(spacing: 14) {
                RendererTuningSlider(
                    title: "Viewport scale",
                    value: $settings.tuning.viewportScale,
                    range: 0.6...1.5,
                    step: 0.01,
                    unit: "×"
                )
                RendererTuningSlider(
                    title: "Viewport X",
                    value: $settings.tuning.viewportOffsetX,
                    range: -120...120,
                    step: 1,
                    unit: "pt"
                )
                RendererTuningSlider(
                    title: "Viewport Y",
                    value: $settings.tuning.viewportOffsetY,
                    range: -120...120,
                    step: 1,
                    unit: "pt"
                )

                Toggle("Ground shadow", isOn: $settings.tuning.showsGroundShadow)
                Toggle("Vehicle animation", isOn: $settings.tuning.animationEnabled)
            }
            .padding(.top, 12)
        }
        .font(.subheadline)
    }
}

private struct RendererCameraControls: View {
    @Bindable var settings: VehicleRendererDebugSettings
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Camera", isExpanded: $isExpanded) {
            VStack(spacing: 14) {
                RendererControlSubheading(title: "Rotation", detail: "degrees")
                RendererTuningSlider(
                    title: "Rotation X",
                    value: $settings.tuning.cameraRotationX,
                    range: -180...180,
                    step: 0.1,
                    unit: "°"
                )
                RendererTuningSlider(
                    title: "Rotation Y",
                    value: $settings.tuning.cameraRotationY,
                    range: -180...180,
                    step: 0.1,
                    unit: "°"
                )
                RendererTuningSlider(
                    title: "Rotation Z",
                    value: $settings.tuning.cameraRotationZ,
                    range: -180...180,
                    step: 0.1,
                    unit: "°"
                )

                RendererControlSubheading(title: "Position", detail: "scene units")
                RendererTuningSlider(
                    title: "Offset X",
                    value: $settings.tuning.cameraOffsetX,
                    range: -15...15,
                    step: 0.01
                )
                RendererTuningSlider(
                    title: "Offset Y",
                    value: $settings.tuning.cameraOffsetY,
                    range: -15...15,
                    step: 0.01
                )
                RendererTuningSlider(
                    title: "Offset Z",
                    value: $settings.tuning.cameraOffsetZ,
                    range: -15...15,
                    step: 0.01
                )
                RendererTuningSlider(
                    title: "Field of view",
                    value: $settings.tuning.fieldOfView,
                    range: 10...100,
                    step: 0.5,
                    unit: "°"
                )
            }
            .padding(.top, 12)
        }
        .font(.subheadline)
    }
}

private struct RendererLightingControls: View {
    @Bindable var settings: VehicleRendererDebugSettings
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Lighting & environment", isExpanded: $isExpanded) {
            VStack(spacing: 14) {
                LabeledContent("Environment") {
                    Picker("Environment", selection: $settings.tuning.environmentAsset) {
                        ForEach(settings.environmentOptions, id: \.self) { environment in
                            Text(environmentDisplayName(environment)).tag(environment)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                RendererTuningSlider(
                    title: "Studio light",
                    value: $settings.tuning.lightingStrength,
                    range: 0.2...3,
                    step: 0.05,
                    unit: "×"
                )
                RendererTuningSlider(
                    title: "Environment energy",
                    value: $settings.tuning.environmentEnergy,
                    range: 0...20,
                    step: 0.1
                )
                RendererTuningSlider(
                    title: "Ambient energy",
                    value: $settings.tuning.ambientEnergy,
                    range: 0...8,
                    step: 0.1
                )

                RendererControlSubheading(title: "Environment rotation", detail: "degrees")
                RendererTuningSlider(
                    title: "Environment X",
                    value: $settings.tuning.environmentRotationX,
                    range: -180...180,
                    step: 0.1,
                    unit: "°"
                )
                RendererTuningSlider(
                    title: "Environment Y",
                    value: $settings.tuning.environmentRotationY,
                    range: -180...180,
                    step: 0.1,
                    unit: "°"
                )
                RendererTuningSlider(
                    title: "Environment Z",
                    value: $settings.tuning.environmentRotationZ,
                    range: -180...180,
                    step: 0.1,
                    unit: "°"
                )

                Toggle("Rotate skybox", isOn: $settings.tuning.rotatesSkybox)
            }
            .padding(.top, 12)
        }
        .font(.subheadline)
    }

    private func environmentDisplayName(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
    }
}

private struct RendererControlSubheading: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct RendererTuningSlider: View {
    let title: LocalizedStringResource
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                TextField(
                    value: $value,
                    format: .number.precision(.fractionLength(3))
                ) {
                    Text(title)
                }
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation)
                .frame(width: 86)

                if let unit {
                    Text(verbatim: unit)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 16, alignment: .leading)
                }
            }

            Slider(value: $value, in: range, step: step) {
                Text(title)
            }
        }
    }
}

private struct RendererVariableReadout: View {
    let settings: VehicleRendererDebugSettings

    @State private var copied = false
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup("Current variables", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal) {
                    Text(verbatim: settings.exportedVariables)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))

                ViewThatFits {
                    HStack(spacing: 8) {
                        actionButtons
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        actionButtons
                    }
                }
            }
            .padding(.top, 12)
        }
        .font(.subheadline)
        .onChange(of: settings.exportedVariables) {
            copied = false
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            UIPasteboard.general.string = settings.exportedVariables
            copied = true
        } label: {
            Label(copied ? "Copied" : "Copy values", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderedProminent)

        Button {
            settings.resetSelectedScene()
        } label: {
            Label("Reset scene", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.bordered)

        Button {
            settings.resetAllScenesForActiveVehicle()
        } label: {
            Label("Reset vehicle", systemImage: "arrow.trianglehead.2.counterclockwise")
        }
        .buttonStyle(.bordered)
    }
}

