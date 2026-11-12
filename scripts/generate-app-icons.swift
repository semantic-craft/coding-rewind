#!/usr/bin/env swift
// SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics
import Foundation

struct CLIOptions {
    var iconsetOutputURL: URL
    var bootstrapArtwork: Bool = false
    var menubarGlyphSourceURL: URL?
}

func parseCLI(repoRoot: URL) -> CLIOptions {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    var options = CLIOptions(
        iconsetOutputURL: repoRoot.appendingPathComponent(".build/AppIcon.iconset", isDirectory: true)
    )
    let args = Array(CommandLine.arguments.dropFirst())
    var idx = 0
    var positionalSet = false
    while idx < args.count {
        let arg = args[idx]
        if arg == "--bootstrap-artwork" {
            options.bootstrapArtwork = true
            idx += 1
        } else if arg == "--menubar-from-glyph" {
            guard idx + 1 < args.count else {
                fputs("Error: --menubar-from-glyph requires an image path\n", stderr)
                exit(2)
            }
            options.menubarGlyphSourceURL = URL(fileURLWithPath: args[idx + 1], relativeTo: cwd).standardizedFileURL
            idx += 2
        } else if arg.hasPrefix("-") {
            fputs("Error: unknown option \(arg)\n", stderr)
            exit(2)
        } else {
            if !positionalSet {
                options.iconsetOutputURL = URL(fileURLWithPath: arg, relativeTo: cwd).standardizedFileURL
                positionalSet = true
            }
            idx += 1
        }
    }
    return options
}

func makeContext(width: Int, height: Int) -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("Error: failed to allocate CGContext \(width)x\(height)\n", stderr)
        exit(1)
    }
    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx
}

func writePNG(cgImage: CGImage, pointSize: NSSize, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = pointSize
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateAppIcons", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to encode PNG for \(url.lastPathComponent)"
        ])
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try pngData.write(to: url, options: .atomic)
}

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(srgbRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
}

func renderMasterArtwork(to destinationURL: URL) throws {
    let size = 1024
    let ctx = makeContext(width: size, height: size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let fullRect = CGRect(x: 0, y: 0, width: size, height: size)

    let tileGradient = CGGradient(
        colorsSpace: space,
        colors: [srgb(0x18, 0x94, 0x83), srgb(0x06, 0x5E, 0x55)] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        tileGradient,
        start: CGPoint(x: 210, y: 930),
        end: CGPoint(x: 820, y: 80),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    let cardPath = CGMutablePath()
    cardPath.move(to: CGPoint(x: 248, y: 230))
    cardPath.addQuadCurve(to: CGPoint(x: 168, y: 310), control: CGPoint(x: 168, y: 230))
    cardPath.addLine(to: CGPoint(x: 168, y: 690))
    cardPath.addQuadCurve(to: CGPoint(x: 248, y: 770), control: CGPoint(x: 168, y: 770))
    cardPath.addLine(to: CGPoint(x: 728, y: 770))
    cardPath.addLine(to: CGPoint(x: 856, y: 642))
    cardPath.addLine(to: CGPoint(x: 856, y: 310))
    cardPath.addQuadCurve(to: CGPoint(x: 776, y: 230), control: CGPoint(x: 856, y: 230))
    cardPath.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 34, color: srgb(0x00, 0x27, 0x22, 0.42))
    ctx.addPath(cardPath)
    ctx.setFillColor(srgb(0xF5, 0xF0, 0xDC))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()
    let paperGradient = CGGradient(
        colorsSpace: space,
        colors: [srgb(0xFF, 0xFC, 0xEE), srgb(0xEB, 0xE5, 0xD0)] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(paperGradient, start: CGPoint(x: 300, y: 800), end: CGPoint(x: 750, y: 210), options: [])
    ctx.restoreGState()

    let foldPath = CGMutablePath()
    foldPath.move(to: CGPoint(x: 728, y: 770))
    foldPath.addLine(to: CGPoint(x: 728, y: 642))
    foldPath.addLine(to: CGPoint(x: 856, y: 642))
    foldPath.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -8, height: -8), blur: 14, color: srgb(0x20, 0x3B, 0x34, 0.22))
    ctx.addPath(foldPath)
    ctx.setFillColor(srgb(0xD9, 0xE7, 0xD6))
    ctx.fillPath()
    ctx.restoreGState()

    let strokeSpecs: [(rect: CGRect, radius: CGFloat)] = [
        (CGRect(x: 286, y: 477, width: 500, height: 58), 29),
        (CGRect(x: 286, y: 373, width: 350, height: 58), 29)
    ]
    for stroke in strokeSpecs {
        let strokePath = CGPath(roundedRect: stroke.rect, cornerWidth: stroke.radius, cornerHeight: stroke.radius, transform: nil)
        ctx.addPath(strokePath)
        ctx.setFillColor(srgb(0x08, 0x70, 0x63))
        ctx.fillPath()
    }

    guard let image = ctx.makeImage() else {
        throw NSError(domain: "GenerateAppIcons", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Failed to create master artwork CGImage"
        ])
    }
    try writePNG(cgImage: image, pointSize: NSSize(width: fullRect.width, height: fullRect.height), to: destinationURL)
}

func loadCGImage(from url: URL) throws -> CGImage {
    guard let data = try? Data(contentsOf: url),
          let rep = NSBitmapImageRep(data: data),
          let cg = rep.cgImage else {
        throw NSError(domain: "GenerateAppIcons", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Failed to load image at \(url.path)"
        ])
    }
    return cg
}

func renderIconset(artwork: CGImage, to iconsetDir: URL) throws {
    let slices: [(String, Int, Int)] = [
        ("icon_16x16.png", 16, 16),
        ("icon_16x16@2x.png", 32, 16),
        ("icon_32x32.png", 32, 32),
        ("icon_32x32@2x.png", 64, 32),
        ("icon_128x128.png", 128, 128),
        ("icon_128x128@2x.png", 256, 128),
        ("icon_256x256.png", 256, 256),
        ("icon_256x256@2x.png", 512, 256),
        ("icon_512x512.png", 512, 512),
        ("icon_512x512@2x.png", 1024, 512)
    ]

    try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

    for (filename, pixelSide, pointSide) in slices {
        let ctx = makeContext(width: pixelSide, height: pixelSide)
        let side = CGFloat(pixelSide)
        let canvas = CGRect(x: 0, y: 0, width: side, height: side)
        let inset = side * 100.0 / 1024.0
        let bounds = canvas.insetBy(dx: inset, dy: inset)
        let corner = bounds.width * 2.0 / 9.0
        let squircle = CGPath(roundedRect: bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)

        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()

        ctx.setFillColor(srgb(0x09, 0x0E, 0x1A, 1.0))
        ctx.fill(bounds)

        ctx.interpolationQuality = .high
        ctx.draw(artwork, in: bounds)

        let rimInset = max(0.5, side * 1.5 / 1024.0)
        let rimBounds = bounds.insetBy(dx: rimInset, dy: rimInset)
        let rimCorner = max(1.0, rimBounds.width * 2.0 / 9.0)
        let rimPath = CGPath(roundedRect: rimBounds, cornerWidth: rimCorner, cornerHeight: rimCorner, transform: nil)
        ctx.addPath(rimPath)
        ctx.setStrokeColor(srgb(0xFF, 0xFF, 0xFF, 0.16))
        ctx.setLineWidth(max(0.75, side * 2.0 / 1024.0))
        ctx.strokePath()
        ctx.restoreGState()

        guard let cg = ctx.makeImage() else { continue }
        try writePNG(
            cgImage: cg,
            pointSize: NSSize(width: pointSide, height: pointSide),
            to: iconsetDir.appendingPathComponent(filename)
        )
    }
}

func renderVectorMenuBarIcons(to resourcesDir: URL) throws {
    for (filename, scale) in [("MenuBarIcon.png", 1), ("MenuBarIcon@2x.png", 2)] {
        let px = 18 * scale
        let ctx = makeContext(width: px, height: px)
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        let card = CGMutablePath()
        card.move(to: CGPoint(x: 4.0, y: 2.5))
        card.addQuadCurve(to: CGPoint(x: 2.5, y: 4.0), control: CGPoint(x: 2.5, y: 2.5))
        card.addLine(to: CGPoint(x: 2.5, y: 13.0))
        card.addQuadCurve(to: CGPoint(x: 4.0, y: 14.5), control: CGPoint(x: 2.5, y: 14.5))
        card.addLine(to: CGPoint(x: 12.1, y: 14.5))
        card.addLine(to: CGPoint(x: 15.5, y: 11.1))
        card.addLine(to: CGPoint(x: 15.5, y: 4.0))
        card.addQuadCurve(to: CGPoint(x: 14.0, y: 2.5), control: CGPoint(x: 15.5, y: 2.5))
        card.closeSubpath()
        ctx.addPath(card)
        ctx.setStrokeColor(srgb(0, 0, 0, 1))
        ctx.setLineWidth(1.35)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        ctx.move(to: CGPoint(x: 12.1, y: 14.5))
        ctx.addLine(to: CGPoint(x: 12.1, y: 11.1))
        ctx.addLine(to: CGPoint(x: 15.5, y: 11.1))
        ctx.strokePath()

        ctx.move(to: CGPoint(x: 5.1, y: 8.8))
        ctx.addLine(to: CGPoint(x: 12.2, y: 8.8))
        ctx.move(to: CGPoint(x: 5.1, y: 6.0))
        ctx.addLine(to: CGPoint(x: 9.4, y: 6.0))
        ctx.strokePath()

        guard let cg = ctx.makeImage() else { continue }
        try writePNG(
            cgImage: cg,
            pointSize: NSSize(width: 18, height: 18),
            to: resourcesDir.appendingPathComponent(filename)
        )
    }
}

func renderMenuBarIconsFromGlyph(sourceURL: URL, to resourcesDir: URL) throws {
    let sourceCG = try loadCGImage(from: sourceURL)
    for (filename, scale) in [("MenuBarIcon.png", 1), ("MenuBarIcon@2x.png", 2)] {
        let px = 18 * scale
        let sampleCtx = makeContext(width: px, height: px)
        let pad = CGFloat(2 * scale)
        sampleCtx.setFillColor(srgb(255, 255, 255, 1))
        sampleCtx.fill(CGRect(x: 0, y: 0, width: px, height: px))
        sampleCtx.interpolationQuality = .high
        sampleCtx.draw(sourceCG, in: CGRect(x: pad, y: pad, width: CGFloat(px) - pad * 2, height: CGFloat(px) - pad * 2))

        let outCtx = makeContext(width: px, height: px)
        guard let inPtr = sampleCtx.data?.assumingMemoryBound(to: UInt8.self),
              let outPtr = outCtx.data?.assumingMemoryBound(to: UInt8.self) else {
            continue
        }
        for y in 0..<px {
            for x in 0..<px {
                let offset = (y * px + x) * 4
                let r = Double(inPtr[offset]) / 255.0
                let g = Double(inPtr[offset + 1]) / 255.0
                let b = Double(inPtr[offset + 2]) / 255.0
                let aIn = Double(inPtr[offset + 3]) / 255.0
                let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let ink = max(0.0, min(1.0, (0.90 - luminance) / 0.70)) * aIn
                outPtr[offset] = 0
                outPtr[offset + 1] = 0
                outPtr[offset + 2] = 0
                outPtr[offset + 3] = UInt8( (ink * 255.0).rounded() )
            }
        }
        guard let outCG = outCtx.makeImage() else { continue }
        try writePNG(
            cgImage: outCG,
            pointSize: NSSize(width: 18, height: 18),
            to: resourcesDir.appendingPathComponent(filename)
        )
    }
}

let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let options = parseCLI(repoRoot: repoRoot)
let resourcesDir = repoRoot.appendingPathComponent("Resources", isDirectory: true)
let artworkURL = resourcesDir.appendingPathComponent("AppIcon-artwork.png")

do {
    try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
    if options.bootstrapArtwork || !FileManager.default.fileExists(atPath: artworkURL.path) {
        try renderMasterArtwork(to: artworkURL)
    }
    let artwork = try loadCGImage(from: artworkURL)
    try renderIconset(artwork: artwork, to: options.iconsetOutputURL)

    if let glyphURL = options.menubarGlyphSourceURL {
        try renderMenuBarIconsFromGlyph(sourceURL: glyphURL, to: resourcesDir)
    } else {
        try renderVectorMenuBarIcons(to: resourcesDir)
    }
    print("Generated iconset at \(options.iconsetOutputURL.path) and menu bar templates in \(resourcesDir.path)")
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
