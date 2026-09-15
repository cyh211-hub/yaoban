// Encode the approved raster brand mark into native macOS icon sizes.
import AppKit
let folder = URL(fileURLWithPath:CommandLine.arguments[1])
guard let source = NSImage(contentsOfFile:CommandLine.arguments[2]) else { fatalError("Missing brand image") }
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
for point in [16,32,128,256,512] {
    for scale in [1,2] {
        let side = point * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:side,pixelsHigh:side,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:side*4,bitsPerPixel:32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in:NSRect(x:0,y:0,width:side,height:side))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"))
    }
}
