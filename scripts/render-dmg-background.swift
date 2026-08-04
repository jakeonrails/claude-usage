#!/usr/bin/env swift
// Renders assets/dmg-background.png (@2x, 1320x800 px for a 660x400 pt DMG window).
// Layout matches scripts/make-dmg.sh: app icon at (165,200), Applications link at
// (495,200), icon size 128 — the arrow points from the app to Applications.
// Re-run only if the layout changes: swift scripts/render-dmg-background.swift

import AppKit

let scale: CGFloat = 2
let size = CGSize(width: 660, height: 400)
let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)

guard let ctx = CGContext(
    data: nil,
    width: Int(pixelSize.width), height: Int(pixelSize.height),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }

ctx.scaleBy(x: scale, y: scale)

// Soft vertical wash, light neutral — legible under both light/dark Finder chrome.
let colors = [
    CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
    CGColor(srgbRed: 0.92, green: 0.93, blue: 0.95, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0), options: [])

// Arrow from app icon toward Applications drop-link. DMG window y-origin is
// top-left; CG here is bottom-left, so icon-center y=200(top) -> 200(bottom)
// happens to coincide for a 400pt-tall window. Icons are 128pt; leave gaps.
let arrowColor = CGColor(srgbRed: 0.55, green: 0.57, blue: 0.62, alpha: 0.9)
let yMid: CGFloat = size.height - 200 - 10 // nudge up toward icon centers
let startX: CGFloat = 165 + 90
let endX: CGFloat = 495 - 90

ctx.setStrokeColor(arrowColor)
ctx.setLineWidth(5)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: startX, y: yMid))
ctx.addLine(to: CGPoint(x: endX - 18, y: yMid))
ctx.strokePath()

ctx.setFillColor(arrowColor)
ctx.move(to: CGPoint(x: endX, y: yMid))
ctx.addLine(to: CGPoint(x: endX - 26, y: yMid + 14))
ctx.addLine(to: CGPoint(x: endX - 26, y: yMid - 14))
ctx.closePath()
ctx.fillPath()

// Caption near the bottom.
let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
rep.size = size // 72dpi *point* size -> tags the PNG as @2x

let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.45, green: 0.47, blue: 0.52, alpha: 1),
]
let caption = NSAttributedString(string: "Drag ClaudeUsage into Applications", attributes: attrs)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let capSize = caption.size()
caption.draw(at: NSPoint(x: (size.width - capSize.width) / 2, y: 36))
NSGraphicsContext.restoreGraphicsState()

let outURL = URL(fileURLWithPath: "assets/dmg-background.png")
try! FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try! rep.representation(using: .png, properties: [:])!.write(to: outURL)
print("wrote \(outURL.path) (\(Int(pixelSize.width))x\(Int(pixelSize.height)) px @2x)")
