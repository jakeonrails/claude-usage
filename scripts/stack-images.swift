// stack-images.swift — stack two PNGs vertically into one, right-aligned.
//
// Usage: swift stack-images.swift <top.png> <bottom.png> <out.png>
// Used by screenshot-menu.sh to place the menu-bar strip (captured by region —
// safe, since the system menu bar is always the topmost layer) above the
// popover (captured by window ID — overlap-proof). Right-aligned because both
// the status item and the popover are anchored to the right edge.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func load(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return img
}

let args = CommandLine.arguments
guard args.count == 4, let top = load(args[1]), let bottom = load(args[2]) else {
    FileHandle.standardError.write("usage: stack-images.swift <top.png> <bottom.png> <out.png>\n".data(using: .utf8)!)
    exit(64)
}

let width = max(top.width, bottom.width)
let height = top.height + bottom.height
guard let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("could not create context\n".data(using: .utf8)!)
    exit(1)
}
// CoreGraphics origin is bottom-left: draw the bottom image first, then the top.
ctx.draw(bottom, in: CGRect(x: width - bottom.width, y: 0, width: bottom.width, height: bottom.height))
ctx.draw(top, in: CGRect(x: width - top.width, y: bottom.height, width: top.width, height: top.height))

guard let out = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write("could not write output\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("finalize failed\n".data(using: .utf8)!)
    exit(1)
}
