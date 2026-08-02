#!/usr/bin/swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Scripts/generate-placeholder-icon.swift
//
// WHY THIS EXISTS: Apple's upload validation rejects a build with no
// app icon at all ("CFBundleIconName is missing") and separately
// rejects any icon that carries an alpha channel. Neither BurlyPhone
// nor BurlyWatch had an icon PNG wired into their AppIcon.appiconset,
// which blocked the first TestFlight upload. This script draws a
// deliberately simple placeholder -- a white barbell silhouette on a
// flat charcoal background -- and writes it as a single 1024x1024 PNG
// with no alpha channel, matching Xcode 26's single-size AppIcon slot
// (one image covers every iOS/watchOS icon size Apple asks for).
//
// USAGE: swift Scripts/generate-placeholder-icon.swift <output.png>
//
// Regenerate with this script rather than hand-editing the PNG so the
// icon asset stays reproducible from source. Run it once per target
// asset catalog:
//   swift Scripts/generate-placeholder-icon.swift BurlyPhone/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//   swift Scripts/generate-placeholder-icon.swift BurlyWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png

import CoreGraphics
import Foundation
import ImageIO

let canvasSize = 1024
let backgroundColor = (r: 0x1C, g: 0x1C, b: 0x1E) // #1C1C1E, flat deep charcoal
let foregroundColor = (r: 0xFF, g: 0xFF, b: 0xFF) // white

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        "Usage: swift generate-placeholder-icon.swift <output.png>\n".data(using: .utf8)!
    )
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let colorSpace = CGColorSpaceCreateDeviceRGB()

// .noneSkipLast means the bitmap carries no alpha channel at all --
// ImageIO writes this out as an 8-bit RGB PNG (color type 2), never
// RGBA, which is what App Store Connect's icon validation requires.
guard let context = CGContext(
    data: nil,
    width: canvasSize,
    height: canvasSize,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("Could not create CGContext")
}

func setFill(_ context: CGContext, _ color: (r: Int, g: Int, b: Int)) {
    context.setFillColor(
        red: CGFloat(color.r) / 255,
        green: CGFloat(color.g) / 255,
        blue: CGFloat(color.b) / 255,
        alpha: 1
    )
}

// Background fill.
setFill(context, backgroundColor)
context.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

// Barbell silhouette: a horizontal bar connecting two vertical plates,
// centered on the canvas. Simple, legible at watch-face size, reads
// as "lifting" without trying to be a finished mark.
setFill(context, foregroundColor)

let midY = CGFloat(canvasSize) / 2
let leftEndX: CGFloat = 170
let rightEndX: CGFloat = 854

// Bar (capsule) connecting the plates.
let barHeight: CGFloat = 88
let barRect = CGRect(x: leftEndX, y: midY - barHeight / 2, width: rightEndX - leftEndX, height: barHeight)
context.addPath(CGPath(
    roundedRect: barRect,
    cornerWidth: barHeight / 2,
    cornerHeight: barHeight / 2,
    transform: nil
))
context.fillPath()

// Plates (rounded rects) centered on each end of the bar.
let plateWidth: CGFloat = 170
let plateHeight: CGFloat = 560
let plateCornerRadius: CGFloat = 52

for centerX in [leftEndX, rightEndX] {
    let plateRect = CGRect(
        x: centerX - plateWidth / 2,
        y: midY - plateHeight / 2,
        width: plateWidth,
        height: plateHeight
    )
    context.addPath(CGPath(
        roundedRect: plateRect,
        cornerWidth: plateCornerRadius,
        cornerHeight: plateCornerRadius,
        transform: nil
    ))
    context.fillPath()
}

guard let cgImage = context.makeImage() else {
    fatalError("Could not create CGImage from context")
}

let url = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("Could not create image destination at \(outputPath)")
}
CGImageDestinationAddImage(destination, cgImage, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Could not finalize PNG at \(outputPath)")
}

print("Wrote \(outputPath) (\(canvasSize)x\(canvasSize), no alpha channel)")
