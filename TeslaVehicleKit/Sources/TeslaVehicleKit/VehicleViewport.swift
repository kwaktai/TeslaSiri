import SwiftUI
import Metal
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A demand-driven, fully local 3D viewport. A still car does not redraw.
/// Drag to orbit, pinch to zoom; set `gestures` to false for a custom host.
@MainActor public struct VehicleViewport: View {
    let experience:VehicleExperience
    let renderer:VehicleFrameRenderer?
    let gestures:Bool
    @State private var drag:CGSize = .zero
    @State private var scale:CGFloat = 1
    @State private var failure:String?
    public init(_ experience:VehicleExperience, renderer:VehicleFrameRenderer?=nil,gestures:Bool=true){self.experience=experience;self.renderer=renderer;self.gestures=gestures}
    public var body:some View {
        Surface(experience:experience,renderer:renderer,revision:experience.revision){failure=$0}
            .id(ObjectIdentifier(experience))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:2).onChanged{v in
                let d=v.translation;experience.orbit(yaw:Float(d.width-drag.width) * -0.008,pitch:Float(d.height-drag.height)*0.006);drag=d
            }.onEnded{_ in drag = .zero},including:gestures ? .all:.none)
            .simultaneousGesture(MagnifyGesture().onChanged{v in experience.zoom(by:Float(v.magnification/scale));scale=v.magnification}.onEnded{_ in scale=1},including:gestures ? .all:.none)
            .overlay{if let failure{Text(failure).font(.caption).padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:8))}}
            .accessibilityLabel("Interactive 3D vehicle")
    }
}

@MainActor private final class Driver {
    let experience:VehicleExperience
    let onError:(String?)->Void
    var renderer:VehicleFrameRenderer?
    weak var pane:Pane?
    var dirty=false,scheduled=false
    var revision:UInt64?
    var lastError:String?
    init(_ experience:VehicleExperience,_ renderer:VehicleFrameRenderer?,_ onError:@escaping(String?)->Void){self.experience=experience;self.renderer=renderer;self.onError=onError}
    func changed(_ r:UInt64){if r != revision{revision=r;request()}}
    func request(){
        dirty=true
        guard !scheduled else{return}
        scheduled=true
        Task { @MainActor [weak self] in
            guard let self else{return};defer{scheduled=false}
            while dirty {
                dirty=false
                guard let pane,pane.window != nil,experience.car != nil,pane.bounds.width>=4,pane.bounds.height>=4 else{return}
                do {
                    if renderer==nil {renderer=try VehicleFrameRenderer(experience)}
                    let gpu=renderer!,layer=pane.metal
                    if layer.device==nil {layer.device=gpu.device;layer.pixelFormat = .bgra8Unorm;layer.framebufferOnly=true}
                    let size=pane.bounds.size, factor=min(pane.displayScale,1600/max(size.width,size.height))
                    let target=CGSize(width:max(4,(size.width*factor).rounded()),height:max(4,(size.height*factor).rounded()))
                    if layer.drawableSize != target {layer.drawableSize=target}
                    guard let drawable=layer.nextDrawable() else{return}
                    try await gpu.draw(into:drawable.texture,present:drawable)
                    if lastError != nil {lastError=nil;onError(nil)}
                } catch is CancellationError {dirty=true}
                catch {let message=String(describing:error);if message != lastError {lastError=message;onError(message)}}
            }
        }
    }
}
#if os(macOS)
private final class Pane:NSView {
    var resized:(()->Void)?
    override func makeBackingLayer()->CALayer { CAMetalLayer() }
    var metal:CAMetalLayer {layer as! CAMetalLayer}
    var displayScale:CGFloat {window?.backingScaleFactor ?? 1}
    override func layout(){super.layout();resized?()}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();resized?()}
}
private struct Surface:NSViewRepresentable {
    let experience:VehicleExperience;let renderer:VehicleFrameRenderer?;let revision:UInt64;let onError:(String?)->Void
    func makeCoordinator()->Driver{Driver(experience,renderer,onError)}
    func makeNSView(context:Context)->Pane{let p=Pane();p.wantsLayer=true;let d=context.coordinator;d.pane=p;p.resized={[weak d] in d?.request()};return p}
    func updateNSView(_ pane:Pane,context:Context){context.coordinator.changed(revision)}
}
#else
private final class Pane:UIView {
    var resized:(()->Void)?
    override class var layerClass:AnyClass { CAMetalLayer.self }
    var metal:CAMetalLayer {layer as! CAMetalLayer}
    var displayScale:CGFloat {traitCollection.displayScale}
    override func layoutSubviews(){super.layoutSubviews();resized?()}
    override func didMoveToWindow(){super.didMoveToWindow();resized?()}
}
private struct Surface:UIViewRepresentable {
    let experience:VehicleExperience;let renderer:VehicleFrameRenderer?;let revision:UInt64;let onError:(String?)->Void
    func makeCoordinator()->Driver{Driver(experience,renderer,onError)}
    func makeUIView(context:Context)->Pane{let p=Pane();let d=context.coordinator;d.pane=p;p.resized={[weak d] in d?.request()};return p}
    func updateUIView(_ pane:Pane,context:Context){context.coordinator.changed(revision)}
}
#endif
