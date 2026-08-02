#!/usr/bin/swift
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO

struct RGB: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    var hex: String {
        String(format: "#%02X%02X%02X", r, g, b)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(
        "app-icon-validator: FAIL: \(message)\n".data(using: .utf8)!
    )
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: swift validate-app-icon.swift <icon.png>")
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("cannot decode \(url.path)")
}
guard image.width == 1024, image.height == 1024 else {
    fail("expected 1024x1024, got \(image.width)x\(image.height)")
}

switch image.alphaInfo {
case .alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast:
    fail("alpha channel is not allowed: \(image.alphaInfo.rawValue)")
default:
    break
}

let width = 1024
let height = 1024
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let inspectionSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: inspectionSpace,
    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fail("cannot allocate inspection bitmap")
}
context.interpolationQuality = .none
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

let background = RGB(r: 0xF0, g: 0x4F, b: 0x2F)
let ink = RGB(r: 0x20, g: 0x17, b: 0x13)
let parchment = RGB(r: 0xFF, g: 0xF0, b: 0xCF)
let approvedColors = [background, ink, parchment]
let antialiasToleranceSquared = 4.0
var backgroundCount = 0
var inkCount = 0
var parchmentCount = 0
let centerX = 512.0
let centerY = 512.0
let safeRadiusSquared = 471.04 * 471.04

func pixelAt(x: Int, y: Int) -> RGB {
    let offset = (y * width + x) * 4
    return RGB(
        r: pixels[offset],
        g: pixels[offset + 1],
        b: pixels[offset + 2]
    )
}

func squaredDistanceFromBlend(
    _ pixel: RGB,
    between first: RGB,
    and second: RGB
) -> Double {
    let point = [Double(pixel.r), Double(pixel.g), Double(pixel.b)]
    let start = [Double(first.r), Double(first.g), Double(first.b)]
    let end = [Double(second.r), Double(second.g), Double(second.b)]
    let direction = zip(end, start).map(-)
    let fromStart = zip(point, start).map(-)
    let lengthSquared = direction.reduce(0) { $0 + $1 * $1 }
    let projection = zip(fromStart, direction).reduce(0) {
        $0 + $1.0 * $1.1
    } / lengthSquared
    let blendAmount = min(1, max(0, projection))

    return zip(point, zip(start, direction)).reduce(0) { distance, values in
        let expected = values.1.0 + values.1.1 * blendAmount
        let difference = values.0 - expected
        return distance + difference * difference
    }
}

func isApprovedAntialiasBlend(_ pixel: RGB, x: Int, y: Int) -> Bool {
    for firstIndex in 0..<approvedColors.count {
        for secondIndex in (firstIndex + 1)..<approvedColors.count {
            let first = approvedColors[firstIndex]
            let second = approvedColors[secondIndex]
            guard squaredDistanceFromBlend(pixel, between: first, and: second)
                    <= antialiasToleranceSquared else {
                continue
            }

            // CoreGraphics antialiasing is a one-pixel raster edge. Require a
            // blend-colored pixel to touch an exact endpoint so flat gradients
            // or textures cannot masquerade as antialiasing in an interior.
            for neighborY in max(0, y - 1)...min(height - 1, y + 1) {
                for neighborX in max(0, x - 1)...min(width - 1, x + 1) {
                    let neighbor = pixelAt(x: neighborX, y: neighborY)
                    if neighbor == first || neighbor == second {
                        return true
                    }
                }
            }
        }
    }
    return false
}

for y in 0..<height {
    for x in 0..<width {
        let pixel = pixelAt(x: x, y: y)
        if pixel == background { backgroundCount += 1 }
        if pixel == ink { inkCount += 1 }
        if pixel == parchment { parchmentCount += 1 }

        if !approvedColors.contains(pixel),
           !isApprovedAntialiasBlend(pixel, x: x, y: y) {
            fail("unauthorized palette color \(pixel.hex) at (\(x), \(y))")
        }

        let dx = Double(x) + 0.5 - centerX
        let dy = Double(y) + 0.5 - centerY
        if dx * dx + dy * dy > safeRadiusSquared, pixel != background {
            fail("non-background pixel outside safe circle at (\(x), \(y))")
        }
    }
}

guard backgroundCount > 0, inkCount > 0, parchmentCount > 0 else {
    fail("approved palette interiors were not all present")
}
print("app-icon-validator: PASS: \(url.path)")
