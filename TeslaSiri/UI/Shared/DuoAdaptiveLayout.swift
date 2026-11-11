import SwiftUI

/// Axis of an active display division (such as the fold on iPhone Duo).
nonisolated enum DuoDivisionAxis: String, Equatable, Sendable {
    /// Horizontal crease dividing top and bottom regions (tabletop / laptop posture).
    case horizontal
    /// Vertical crease dividing leading and trailing regions (book posture).
    case vertical
}

/// Sendable snapshot of viewport geometry and any overlapping `.division` reserved region.
nonisolated struct DuoGeometryReading: Equatable, Sendable {
    var viewportSize: CGSize = .zero
    var divisionFrame: CGRect? = nil

    var divisionAxis: DuoDivisionAxis? {
        guard let divisionFrame else { return nil }
        return divisionFrame.width >= divisionFrame.height ? .horizontal : .vertical
    }
}

/// Normalized hinge state across foldable and flat devices.
nonisolated enum DuoHingeState: Equatable, Sendable {
    case unavailable
    case closed
    case partiallyOpen(angleDegrees: Double)
    case fullyOpen
}

/// Adaptive posture model for iPhone Duo outer/inner displays, fold divisions, and reachability.
struct DuoPosture: Equatable {
    var hingeState: DuoHingeState = .unavailable
    var horizontalSizeClass: UserInterfaceSizeClass? = .compact
    var verticalSizeClass: UserInterfaceSizeClass? = .regular
    var geometry: DuoGeometryReading = DuoGeometryReading()

    /// True when viewing the closed outer display of iPhone Duo.
    var isClosedOuterDisplay: Bool {
        hingeState == .closed
    }

    /// True when an active `.division` reserved region overlaps the current view.
    var hasActiveDivision: Bool {
        geometry.divisionFrame != nil
    }

    /// True when the hinge is partially folded or a division crease is active.
    var isPartiallyOpen: Bool {
        if case .partiallyOpen = hingeState {
            return true
        }
        return hasActiveDivision
    }

    /// Uses SwiftUI's `ArrangementView(.split)` on the inner display (flat or folded)
    /// and regular-width workspaces, while avoiding split mode on the closed outer display
    /// (where landscape split hides `secondary`) and narrow Split View multitasking panes.
    var prefersSplitArrangement: Bool {
        !isClosedOuterDisplay && (horizontalSizeClass == .regular || hasActiveDivision)
    }

    /// Compacts vertical hero chrome on iPhone Duo's shorter outer display and short viewports
    /// so primary controls stay within immediate thumb reach without scrolling.
    var prefersCompactHero: Bool {
        if isClosedOuterDisplay || verticalSizeClass == .compact {
            return true
        }
        let height = geometry.viewportSize.height
        return height > 0 && height < 690
    }

    /// Adaptive map height for compact single-column layouts so route playback controls remain reachable.
    var compactMapHeight: CGFloat {
        if isClosedOuterDisplay || verticalSizeClass == .compact {
            return 204
        }
        let height = geometry.viewportSize.height
        if height > 0 && height < 720 {
            return 220
        }
        return 264
    }
}

extension EnvironmentValues {
    @Entry var duoPosture: DuoPosture = DuoPosture()
}

private struct DuoPostureObserverModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var hingeState: DuoHingeState = .unavailable
    @State private var geometry = DuoGeometryReading()

    private var posture: DuoPosture {
        DuoPosture(
            hingeState: hingeState,
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            geometry: geometry
        )
    }

    func body(content: Content) -> some View {
        if #available(iOS 27.3, macOS 27.3, visionOS 27.3, *) {
            content
                .environment(\.duoPosture, posture)
                .onHingeChange { _, newContext in
                    hingeState = Self.mapHinge(newContext.hinge)
                }
                .onGeometryChange(for: DuoGeometryReading.self) { proxy in
                    let divisions = proxy.reservedRegions(
                        kind: .division,
                        layoutDirectionBehavior: .fixed
                    )
                    return DuoGeometryReading(
                        viewportSize: proxy.size,
                        divisionFrame: divisions.first?.frame
                    )
                } action: { _, newReading in
                    geometry = newReading
                }
        } else {
            content
                .environment(\.duoPosture, posture)
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { _, newSize in
                    geometry = DuoGeometryReading(viewportSize: newSize, divisionFrame: nil)
                }
        }
    }

    @available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
    private static func mapHinge(_ hinge: DeviceHinge?) -> DuoHingeState {
        guard let hinge else { return .unavailable }
        switch hinge.status {
        case .closed:
            return .closed
        case .partiallyOpen:
            return .partiallyOpen(angleDegrees: hinge.angle.degrees)
        case .fullyOpen:
            return .fullyOpen
        default:
            return .unavailable
        }
    }
}

/// Two-pane workspace backed by `ArrangementView(.split)` on iOS 27.3+.
/// Keep this out of outer `ScrollView` containers so `ArrangementView` can manage division regions directly.
struct DuoSplitWorkspace<Primary: View, Secondary: View>: View {
    var primaryRatio: CGFloat = 0.5
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if #available(iOS 27.3, macOS 27.3, visionOS 27.3, *) {
            ArrangementView {
                primary()
                    .splitArrangementLayoutRatio(primaryRatio)
            } secondary: {
                secondary()
            }
            .arrangementViewStyle(.split)
        } else if horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: 0) {
                primary()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                secondary()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                primary()
                secondary()
            }
        }
    }
}

private struct DuoSingleCardStageModifier: ViewModifier {
    @Environment(\.duoPosture) private var posture
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        if let division = posture.geometry.divisionFrame {
            switch posture.geometry.divisionAxis {
            case .vertical:
                // Place standalone interactive cards cleanly on the thumb-reachable trailing side of a vertical fold.
                let leadingClearance = max(0, division.maxX + 8)
                let trailingSideOffset = layoutDirection == .leftToRight ? leadingClearance : max(0, posture.geometry.viewportSize.width - division.minX + 8)
                content
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.leading, trailingSideOffset)
            case .horizontal:
                // In tabletop / laptop fold, place standalone interactive cards on the flat lower half.
                let topClearance = max(0, division.maxY + 8)
                content
                    .frame(maxWidth: AppTheme.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.top, topClearance)
            case nil:
                content.readableContentWidth()
            }
        } else {
            content.readableContentWidth()
        }
    }
}

extension View {
    /// Observes hinge state, viewport size, and `.division` reserved regions without introducing layout wrappers.
    func observeDuoPosture() -> some View {
        modifier(DuoPostureObserverModifier())
    }

    /// Keeps standalone cards (sign-in, empty, error) clear of an active fold crease and within thumb reach.
    func duoSingleCardStage() -> some View {
        modifier(DuoSingleCardStageModifier())
    }
}
