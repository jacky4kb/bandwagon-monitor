import AppKit
let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: 1) }
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let t = AffineTransform(scale: CGFloat(pixels)/1024)
        (t as NSAffineTransform).concat()
        color(16,27,36).setFill()
        NSBezierPath(roundedRect: NSRect(x:48,y:48,width:928,height:928),xRadius:218,yRadius:218).fill()
        for y in [260,430,600] {
            let rect = NSBezierPath(roundedRect: NSRect(x:240,y:y,width:544,height:128),xRadius:28,yRadius:28)
            color(25,58,52).setFill(); rect.fill()
            color(89,232,191).setStroke(); rect.lineWidth=14; rect.stroke()
            color(89,232,191).setFill()
            NSBezierPath(ovalIn:NSRect(x:280,y:y+48,width:32,height:32)).fill()
            NSBezierPath(roundedRect:NSRect(x:574,y:y+56,width:158,height:16),xRadius:8,yRadius:8).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:folder).appendingPathComponent(name))
    }
}
