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

    let bgGradient = CGGradient(
        colorsSpace: space,
        colors: [
            srgb(0x16, 0x24, 0x47, 1.0),
            srgb(0x0D, 0x16, 0x2C, 1.0),
            srgb(0x09, 0x0E, 0x1A, 1.0)
        ] as CFArray,
        locations: [0.0, 0.52, 1.0]
    )!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: 160, y: 960),
        end: CGPoint(x: 880, y: 64),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    let cyanAura = CGGradient(
        colorsSpace: space,
        colors: [srgb(0x38, 0xBD, 0xF8, 0.26), srgb(0x38, 0xBD, 0xF8, 0.0)] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        cyanAura,
        startCenter: CGPoint(x: 430, y: 600),
        startRadius: 10,
        endCenter: CGPoint(x: 430, y: 600),
        endRadius: 430,
        options: []
    )

    let amberAura = CGGradient(
        colorsSpace: space,
        colors: [srgb(0xF5, 0x9E, 0x0B, 0.22), srgb(0xF5, 0x9E, 0x0B, 0.0)] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        amberAura,
        startCenter: CGPoint(x: 610, y: 390),
        startRadius: 10,
        endCenter: CGPoint(x: 610, y: 390),
        endRadius: 390,
        options: []
    )

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 150, y: 150, width: 724, height: 724))
    ctx.clip()
    ctx.setStrokeColor(srgb(0x7D, 0xD3, 0xFC, 0.065))
    ctx.setLineWidth(1.5)
    for step in stride(from: 192, through: 832, by: 64) {
        let pos = CGFloat(step)
        ctx.move(to: CGPoint(x: pos, y: 150))
        ctx.addLine(to: CGPoint(x: pos, y: 874))
        ctx.move(to: CGPoint(x: 150, y: pos))
        ctx.addLine(to: CGPoint(x: 874, y: pos))
    }
    ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.translateBy(x: 512, y: 506)
    ctx.rotate(by: -9.0 * .pi / 180.0)
    let cardRect = CGRect(x: -186, y: -144, width: 372, height: 288)
    let cardPath = CGPath(roundedRect: cardRect, cornerWidth: 46, cornerHeight: 46, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: srgb(0x02, 0x06, 0x17, 0.65))
    ctx.addPath(cardPath)
    ctx.setFillColor(srgb(0x1E, 0x29, 0x3B, 0.55))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()
    let glassGrad = CGGradient(
        colorsSpace: space,
        colors: [
            srgb(0xFF, 0xFF, 0xFF, 0.20),
            srgb(0x93, 0xC5, 0xFD, 0.09),
            srgb(0x0F, 0x17, 0x2A, 0.36)
        ] as CFArray,
        locations: [0.0, 0.5, 1.0]
    )!
    ctx.drawLinearGradient(
        glassGrad,
        start: CGPoint(x: cardRect.minX, y: cardRect.maxY),
        end: CGPoint(x: cardRect.maxX, y: cardRect.minY),
        options: []
    )
    ctx.restoreGState()

    ctx.addPath(cardPath)
    ctx.setStrokeColor(srgb(0xE0, 0xF2, 0xFE, 0.34))
    ctx.setLineWidth(3.0)
    ctx.strokePath()

    let barSpecs: [(CGRect, CGColor)] = [
        (CGRect(x: -128, y: 58, width: 148, height: 22), srgb(0x38, 0xBD, 0xF8, 0.85)),
        (CGRect(x: -128, y: 8, width: 248, height: 18), srgb(0xE2, 0xE8, 0xF0, 0.52)),
        (CGRect(x: -128, y: -38, width: 204, height: 18), srgb(0xE2, 0xE8, 0xF0, 0.36)),
        (CGRect(x: -128, y: -84, width: 126, height: 18), srgb(0xFB, 0xBF, 0x24, 0.65))
    ]
    for (barRect, color) in barSpecs {
        let barPath = CGPath(roundedRect: barRect, cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.addPath(barPath)
        ctx.setFillColor(color)
        ctx.fillPath()
    }
    ctx.restoreGState()

    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 296
    let startAngle = -142.0 * .pi / 180.0
    let arcEndAngle = 114.0 * .pi / 180.0
    let arcCenterline = CGMutablePath()
    let arcSteps = 160
    for i in 0...arcSteps {
        let t = CGFloat(i) / CGFloat(arcSteps)
        let angle = startAngle + t * (arcEndAngle - startAngle)
        let pt = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        if i == 0 {
            arcCenterline.move(to: pt)
        } else {
            arcCenterline.addLine(to: pt)
        }
    }
    let strokedArc = arcCenterline.copy(
        strokingWithWidth: 54,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 10
    )

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: srgb(0x38, 0xBD, 0xF8, 0.50))
    ctx.addPath(strokedArc)
    ctx.setFillColor(srgb(0x38, 0xBD, 0xF8, 0.25))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(strokedArc)
    ctx.clip()
    let arcGrad = CGGradient(
        colorsSpace: space,
        colors: [
            srgb(0x38, 0xBD, 0xF8, 1.0),
            srgb(0x0E, 0xA5, 0xE9, 1.0),
            srgb(0xFB, 0xBF, 0x24, 1.0),
            srgb(0xF5, 0x9E, 0x0B, 1.0)
        ] as CFArray,
        locations: [0.0, 0.48, 0.84, 1.0]
    )!
    ctx.drawLinearGradient(
        arcGrad,
        start: CGPoint(x: 320, y: 240),
        end: CGPoint(x: 380, y: 790),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    for (chevAngleDeg, alphaScale, width) in [(138.0 as CGFloat, 1.0 as CGFloat, 42.0 as CGFloat), (120.0 as CGFloat, 0.82 as CGFloat, 38.0 as CGFloat)] {
        let shiftedAngle = chevAngleDeg * .pi / 180.0
        let tip = CGPoint(
            x: center.x + cos(shiftedAngle) * radius,
            y: center.y + sin(shiftedAngle) * radius
        )
        let localTangent = shiftedAngle + .pi / 2.0
        let wingLen: CGFloat = 88
        let wingA = CGPoint(
            x: tip.x + cos(localTangent + 2.38) * wingLen,
            y: tip.y + sin(localTangent + 2.38) * wingLen
        )
        let wingB = CGPoint(
            x: tip.x + cos(localTangent - 2.38) * wingLen,
            y: tip.y + sin(localTangent - 2.38) * wingLen
        )
        let chev = CGMutablePath()
        chev.move(to: wingA)
        chev.addLine(to: tip)
        chev.addLine(to: wingB)
        let strokedChev = chev.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 20, color: srgb(0xF5, 0x9E, 0x0B, 0.55 * alphaScale))
        ctx.addPath(strokedChev)
        ctx.setFillColor(srgb(0xFB, 0xBF, 0x24, alphaScale))
        ctx.fillPath()
        ctx.restoreGState()
    }

    let sparkCenter = CGPoint(x: 534, y: 504)
    let sparkGlow = CGGradient(
        colorsSpace: space,
        colors: [srgb(0xFD, 0xE6, 0x8A, 0.90), srgb(0xF5, 0x9E, 0x0B, 0.0)] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        sparkGlow,
        startCenter: sparkCenter,
        startRadius: 4,
        endCenter: sparkCenter,
        endRadius: 96,
        options: []
    )

    let sparkPath = CGMutablePath()
    let outerR: CGFloat = 54
    let innerR: CGFloat = 16
    for i in 0..<8 {
        let angle = CGFloat(i) * (.pi / 4.0)
        let r = (i % 2 == 0) ? outerR : innerR
        let pt = CGPoint(x: sparkCenter.x + cos(angle) * r, y: sparkCenter.y + sin(angle) * r)
        if i == 0 {
            sparkPath.move(to: pt)
        } else {
            sparkPath.addLine(to: pt)
        }
    }
    sparkPath.closeSubpath()
    ctx.addPath(sparkPath)
    ctx.setFillColor(srgb(0xFE, 0xF3, 0xC7, 1.0))
    ctx.fillPath()

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
        ctx.setStrokeColor(srgb(0, 0, 0, 1))
        ctx.setLineWidth(1.75)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let center = CGPoint(x: 9.2, y: 8.8)
        let radius: CGFloat = 6.1
        let startAngle = -140.0 * .pi / 180.0
        let arcEndAngle = 122.0 * .pi / 180.0
        let tipAngle = 132.0 * .pi / 180.0
        let arcPath = CGMutablePath()
        let steps = 64
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let angle = startAngle + t * (arcEndAngle - startAngle)
            let pt = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 {
                arcPath.move(to: pt)
            } else {
                arcPath.addLine(to: pt)
            }
        }
        let tip = CGPoint(x: center.x + cos(tipAngle) * radius, y: center.y + sin(tipAngle) * radius)
        arcPath.addLine(to: tip)
        ctx.addPath(arcPath)
        ctx.strokePath()

        let tangent = tipAngle + .pi / 2.0
        let wingLength: CGFloat = 3.25
        let wingA = CGPoint(
            x: tip.x + cos(tangent + 2.32) * wingLength,
            y: tip.y + sin(tangent + 2.32) * wingLength
        )
        let wingB = CGPoint(
            x: tip.x + cos(tangent - 2.32) * wingLength,
            y: tip.y + sin(tangent - 2.32) * wingLength
        )
        ctx.move(to: wingA)
        ctx.addLine(to: tip)
        ctx.addLine(to: wingB)
        ctx.strokePath()

        ctx.setLineWidth(1.65)
        ctx.move(to: CGPoint(x: 6.7, y: 10.1))
        ctx.addLine(to: CGPoint(x: 11.8, y: 10.1))
        ctx.move(to: CGPoint(x: 6.7, y: 7.4))
        ctx.addLine(to: CGPoint(x: 10.3, y: 7.4))
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
