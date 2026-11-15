import CoreGraphics
import CoreImage
import Foundation
import Metal

extension VehicleFrameRenderer {
    /// Photograph the live scene, including its current lens, open parts, light
    /// switches and finish. Use the viewport's renderer, not a second scene.
    /// Classic resolves its display-RGB samples directly to the requested size.
    /// Softbox exports retain their optional linear-light Lanczos reduction.
    public func image(width:Int,height:Int,supersample:Int=1) async throws -> CGImage {
        let look = currentLook
        let scale = look == .classic ? 1 : supersample
        guard (1...2).contains(supersample),width>=4,height>=4,width<=4096/scale,height<=4096/scale
        else{throw VehicleError.invalid("Invalid still size or sample count")}
        let w=width*scale,h=height*scale
        let t=try makeOutput(width:w,height:h)
        try await draw(into:t,present:nil,expectedLook:look)
        var bytes=Data(count:w*h*4)
        bytes.withUnsafeMutableBytes{t.getBytes($0.baseAddress!,bytesPerRow:w*4,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)}
        let srgb=CGColorSpace(name:CGColorSpace.sRGB)!
        let info=CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.noneSkipFirst.rawValue)
        guard let full=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:srgb,bitmapInfo:info,provider:CGDataProvider(data:bytes as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
        else{throw VehicleError.invalid("Cannot read the rendered frame")}
        if scale==1{return full}
        let ci=CIContext(mtlDevice:device,options:[.cacheIntermediates:false])
        let scaled=CIImage(cgImage:full).clampedToExtent().applyingFilter("CILanczosScaleTransform",parameters:["inputScale":1.0/Double(supersample),"inputAspectRatio":1.0])
        guard let result=ci.createCGImage(scaled,from:CGRect(x:0,y:0,width:width,height:height),format:.RGBA8,colorSpace:srgb)
        else{throw VehicleError.invalid("Cannot resolve supersampled frame")}
        return result
    }
}
