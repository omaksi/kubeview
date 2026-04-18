#!/usr/bin/env swift
// Generates Resources/AppIcon.icns from SF Symbols + Core Graphics.
// Coral→amber gradient squircle, white hexagon outline, binoculars glyph.
// Usage: ./scripts/make_icon.swift (from repo root)

import AppKit
import CoreGraphics
import Foundation

let sizes: [(px: Int, name: String)] = [
    (16,  "icon_16x16.png"),
    (32,  "icon_16x16@2x.png"),
    (32,  "icon_32x32.png"),
    (64,  "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024,"icon_512x512@2x.png"),
]

func renderIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = CGRect(x: 0, y: 0, width: s, height: s)

    // Squircle clip (macOS icon corner radius ≈ 0.2237 of side).
    let squircle = NSBezierPath(roundedRect: rect,
                                xRadius: s * 0.2237,
                                yRadius: s * 0.2237)
    squircle.addClip()

    // Deep teal gradient: slate-teal top-left → brighter teal bottom-right.
    // Distinct from Lens (navy), k9s (green), and stock Kubernetes blue.
    let gradient = NSGradient(starting: NSColor(red: 0.10, green: 0.24, blue: 0.32, alpha: 1.0),
                              ending:   NSColor(red: 0.22, green: 0.55, blue: 0.63, alpha: 1.0))!
    gradient.draw(in: rect, angle: 135)

    // Hexagon frame centered; flat top for a solid silhouette.
    let cx = s / 2
    let cy = s / 2
    let hexR = s * 0.38
    let hex = NSBezierPath()
    for i in 0..<6 {
        let angle = Double(i) * (.pi / 3) - .pi / 2
        let x = cx + hexR * CGFloat(cos(angle))
        let y = cy + hexR * CGFloat(sin(angle))
        if i == 0 { hex.move(to: CGPoint(x: x, y: y)) }
        else      { hex.line(to: CGPoint(x: x, y: y)) }
    }
    hex.close()

    // Subtle fill + white rim.
    NSColor.white.withAlphaComponent(0.14).setFill()
    hex.fill()
    NSColor.white.setStroke()
    hex.lineWidth = max(1, s * 0.025)
    hex.stroke()

    // Binoculars symbol in white, sized to fit inside hexagon.
    let pt = s * 0.42
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .semibold)
    guard let raw = NSImage(systemSymbolName: "binoculars.fill",
                            accessibilityDescription: nil)?
                       .withSymbolConfiguration(cfg)
    else { return image }

    let symSize = raw.size
    let tinted = NSImage(size: symSize, flipped: false) { r in
        raw.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceIn)
        return true
    }
    let symRect = CGRect(x: cx - symSize.width / 2,
                         y: cy - symSize.height / 2,
                         width: symSize.width,
                         height: symSize.height)
    tinted.draw(in: symRect)

    return image
}

func writePNG(_ image: NSImage, to url: URL, pixels: Int) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff)
    else { throw NSError(domain: "icon", code: 1) }
    rep.size = NSSize(width: pixels, height: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 2)
    }
    try png.write(to: url)
}

let fm = FileManager.default
let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
let resources = cwd.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")
try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for (px, name) in sizes {
    let img = renderIcon(size: px)
    let out = iconset.appendingPathComponent(name)
    try writePNG(img, to: out, pixels: px)
    print("  \(name)  \(px)×\(px)")
}

// Run iconutil to produce .icns.
let icns = resources.appendingPathComponent("AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
try task.run()
task.waitUntilExit()

if task.terminationStatus == 0 {
    print("\nWrote \(icns.path)")
} else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
