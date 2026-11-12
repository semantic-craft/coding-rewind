#!/usr/bin/env swift
// SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics
import Foundation

struct OpaqueBounds: CustomStringConvertible {
    let minX: Int
    let maxX: Int
    let minY: Int
    let maxY: Int

    var description: String {
        "[\(minX)...\(maxX), \(minY)...\(maxY)]"
    }
}

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

func rasterizeAlphaBuffer(cgImage: CGImage) -> (width: Int, height: Int, bytes: [UInt8]) {
    let width = cgImage.width
    let height = cgImage.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    buffer.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress,
              let ctx = CGContext(
                  data: base,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            fail("Unable to allocate verification bitmap \(width)x\(height)")
        }
        ctx.setBlendMode(.copy)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (width, height, buffer)
}

func loadRasterizedPNG(at url: URL) -> (width: Int, height: Int, bytes: [UInt8]) {
    guard let data = try? Data(contentsOf: url),
          let rep = NSBitmapImageRep(data: data),
          let cg = rep.cgImage else {
        fail("Missing or unreadable PNG at \(url.path)")
    }
    return rasterizeAlphaBuffer(cgImage: cg)
}

func computeOpaqueBounds(width: Int, height: Int, bytes: [UInt8], source: String, threshold: Double = 0.5) -> OpaqueBounds {
    var minX = width
    var maxX = -1
    var minY = height
    var maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let alpha = Double(bytes[(y * width + x) * 4 + 3]) / 255.0
            if alpha >= threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    guard maxX >= minX && maxY >= minY else {
        fail("No opaque pixels (alpha >= \(threshold)) found in \(width)x\(height) image at \(source)")
    }
    return OpaqueBounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
}

func referenceMailBounds(side: Int) -> OpaqueBounds {
    let mailPath = "/System/Applications/Mail.app"
    guard FileManager.default.fileExists(atPath: mailPath) else {
        let inset = Int((Double(side) * 100.0 / 1024.0).rounded(.down))
        return OpaqueBounds(minX: inset, maxX: side - 1 - inset, minY: inset, maxY: side - 1 - inset)
    }
    guard let mailBundle = Bundle(url: URL(fileURLWithPath: mailPath)),
          let iconName = mailBundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
          let resourcesURL = mailBundle.resourceURL else {
        fail("Unable to locate Mail.app icon resource in \(mailPath)")
    }
    let iconURL = resourcesURL.appendingPathComponent(iconName)
    let resolvedIconURL = iconURL.pathExtension.isEmpty ? iconURL.appendingPathExtension("icns") : iconURL
    guard let icon = NSImage(contentsOf: resolvedIconURL) else {
        fail("Unable to read Mail.app icon resource at \(resolvedIconURL.path)")
    }
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: side,
        pixelsHigh: side,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: side * 4,
        bitsPerPixel: 32
    ) else {
        fail("Unable to create reference bitmap at \(side)px")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    guard let cg = rep.cgImage else {
        fail("Unable to extract reference CGImage at \(side)px")
    }
    let raster = rasterizeAlphaBuffer(cgImage: cg)
    return computeOpaqueBounds(width: raster.width, height: raster.height, bytes: raster.bytes, source: resolvedIconURL.path, threshold: 0.5)
}

let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

let args = Array(CommandLine.arguments.dropFirst())
let iconsetDir: URL = args.first.map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL }
    ?? repoRoot.appendingPathComponent(".build/AppIcon.iconset", isDirectory: true)
let resourcesDir: URL = (args.count > 1)
    ? URL(fileURLWithPath: args[1], relativeTo: cwd).standardizedFileURL
    : repoRoot.appendingPathComponent("Resources", isDirectory: true)

let expectedSlices: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

var rasterBySlice: [String: (width: Int, height: Int, bytes: [UInt8])] = [:]
for (name, expectedSide) in expectedSlices {
    let url = iconsetDir.appendingPathComponent(name)
    let raster = loadRasterizedPNG(at: url)
    if raster.width != expectedSide || raster.height != expectedSide {
        fail("\(name) dimensions \(raster.width)x\(raster.height) != expected \(expectedSide)x\(expectedSide)")
    }
    rasterBySlice[name] = raster
}

let benchmarkSlices: [(String, Int)] = [
    ("icon_128x128.png", 128),
    ("icon_256x256.png", 256),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, side) in benchmarkSlices {
    guard let raster = rasterBySlice[name] else { continue }
    let actual = computeOpaqueBounds(width: raster.width, height: raster.height, bytes: raster.bytes, source: iconsetDir.appendingPathComponent(name).path, threshold: 0.5)
    let expected = referenceMailBounds(side: side)
    let delta = max(
        abs(actual.minX - expected.minX),
        abs(actual.maxX - expected.maxX),
        abs(actual.minY - expected.minY),
        abs(actual.maxY - expected.maxY)
    )
    if delta > 1 {
        fail("\(name) opaque bounds \(actual) differ from Mail.app \(expected) by \(delta)px (> 1px)")
    }
}

for (menuFile, expectedSide) in [("MenuBarIcon.png", 18), ("MenuBarIcon@2x.png", 36)] {
    let url = resourcesDir.appendingPathComponent(menuFile)
    let raster = loadRasterizedPNG(at: url)
    if raster.width != expectedSide || raster.height != expectedSide {
        fail("\(menuFile) dimensions \(raster.width)x\(raster.height) != expected \(expectedSide)x\(expectedSide)")
    }

    let corners = [
        (0, 0),
        (expectedSide - 1, 0),
        (0, expectedSide - 1),
        (expectedSide - 1, expectedSide - 1)
    ]
    for (cx, cy) in corners {
        let cornerAlpha = Double(raster.bytes[(cy * expectedSide + cx) * 4 + 3]) / 255.0
        if cornerAlpha >= 0.05 {
            fail("\(menuFile) corner (\(cx),\(cy)) alpha \(cornerAlpha) >= 0.05 (not transparent)")
        }
    }

    var strokePixels = 0
    let totalPixels = expectedSide * expectedSide
    for idx in 0..<totalPixels {
        let alpha = Double(raster.bytes[idx * 4 + 3]) / 255.0
        if alpha >= 0.35 {
            strokePixels += 1
        }
    }
    let coverage = Double(strokePixels) / Double(totalPixels)
    if !(0.08...0.55).contains(coverage) {
        fail("\(menuFile) stroke coverage \(String(format: "%.3f", coverage)) outside 0.08...0.55")
    }
}

print("PASS: AppIcon.iconset matches Mail.app squircle within <=1px and MenuBarIcon @1x/@2x templates verified.")
