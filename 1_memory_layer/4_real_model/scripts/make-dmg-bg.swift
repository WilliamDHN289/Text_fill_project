import AppKit
import CoreGraphics

let width = 500
let height = 270

guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

context.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

let cx: CGFloat = 250
let cy: CGFloat = CGFloat(height) - 130
context.setStrokeColor(CGColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1.0))
context.setLineWidth(2.5)
context.setLineCap(.round)
context.setLineJoin(.round)

context.move(to: CGPoint(x: cx - 32, y: cy))
context.addLine(to: CGPoint(x: cx + 32, y: cy))
context.move(to: CGPoint(x: cx + 22, y: cy + 12))
context.addLine(to: CGPoint(x: cx + 32, y: cy))
context.addLine(to: CGPoint(x: cx + 22, y: cy - 12))
context.strokePath()

guard let cgImage = context.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
        "public.png" as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, cgImage, nil)
CGImageDestinationFinalize(dest)
print("Wrote \(width)x\(height) PNG to \(CommandLine.arguments[1])")
