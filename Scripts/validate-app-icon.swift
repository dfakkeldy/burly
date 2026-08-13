#!/usr/bin/swift
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO

struct RGB: Hashable {
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
let approvedColorPairs = [(0, 1), (0, 2), (1, 2)]
let antialiasToleranceSquared = 4.0
var blendPairIndices = [Int](repeating: -1, count: width * height)
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

func approvedBlendPairIndex(for pixel: RGB) -> Int? {
    var closestPairIndex: Int?
    var closestDistance = Double.infinity
    for (pairIndex, pair) in approvedColorPairs.enumerated() {
        let distance = squaredDistanceFromBlend(
            pixel,
            between: approvedColors[pair.0],
            and: approvedColors[pair.1]
        )
        if distance < closestDistance {
            closestDistance = distance
            closestPairIndex = pairIndex
        }
    }
    return closestDistance <= antialiasToleranceSquared ? closestPairIndex : nil
}

for y in 0..<height {
    for x in 0..<width {
        let pixel = pixelAt(x: x, y: y)
        if pixel == background { backgroundCount += 1 }
        if pixel == ink { inkCount += 1 }
        if pixel == parchment { parchmentCount += 1 }

        if !approvedColors.contains(pixel) {
            guard let pairIndex = approvedBlendPairIndex(for: pixel) else {
                fail("unauthorized palette color \(pixel.hex) at (\(x), \(y))")
            }
            blendPairIndices[y * width + x] = pairIndex
        }

        let dx = Double(x) + 0.5 - centerX
        let dy = Double(y) + 0.5 - centerY
        if dx * dx + dy * dy > safeRadiusSquared, pixel != background {
            fail("non-background pixel outside safe circle at (\(x), \(y))")
        }
    }
}

var visitedBlendPixels = [Bool](repeating: false, count: width * height)
for y in 0..<height {
    for x in 0..<width {
        let startIndex = y * width + x
        let pairIndex = blendPairIndices[startIndex]
        guard pairIndex >= 0, !visitedBlendPixels[startIndex] else {
            continue
        }

        let pair = approvedColorPairs[pairIndex]
        let first = approvedColors[pair.0]
        let second = approvedColors[pair.1]
        var touchesFirst = false
        var touchesSecond = false
        var component = [startIndex]
        var componentColors = Set<RGB>()
        visitedBlendPixels[startIndex] = true
        var nextComponentIndex = 0

        while nextComponentIndex < component.count {
            let pixelIndex = component[nextComponentIndex]
            nextComponentIndex += 1
            let pixelX = pixelIndex % width
            let pixelY = pixelIndex / width
            componentColors.insert(pixelAt(x: pixelX, y: pixelY))
            var touchesEndpointAtPixel = false

            for neighborY in max(0, pixelY - 1)...min(height - 1, pixelY + 1) {
                for neighborX in max(0, pixelX - 1)...min(width - 1, pixelX + 1) {
                    let neighborIndex = neighborY * width + neighborX
                    let neighbor = pixelAt(x: neighborX, y: neighborY)
                    touchesFirst = touchesFirst || neighbor == first
                    touchesSecond = touchesSecond || neighbor == second
                    touchesEndpointAtPixel = touchesEndpointAtPixel
                        || neighbor == first
                        || neighbor == second

                    if blendPairIndices[neighborIndex] == pairIndex,
                       !visitedBlendPixels[neighborIndex] {
                        visitedBlendPixels[neighborIndex] = true
                        component.append(neighborIndex)
                    }
                }
            }

            if !touchesEndpointAtPixel {
                let pixel = pixelAt(x: pixelX, y: pixelY)
                fail(
                    "unauthorized palette color \(pixel.hex) "
                        + "at (\(pixelX), \(pixelY)): blend pixel is not on a palette edge"
                )
            }
        }

        // A normal edge component reaches both flat endpoint colors. A source
        // feature narrower than one pixel may never reach full coverage, but
        // CoreGraphics still emits a multi-step ramp rather than one stray
        // blend value; preserve those deterministic subpixel components.
        let reachesBothEndpoints = touchesFirst && touchesSecond
        let hasSubpixelTransitionRamp = (touchesFirst || touchesSecond)
            && componentColors.count >= 3
        if !reachesBothEndpoints && !hasSubpixelTransitionRamp {
            let pixel = pixelAt(x: x, y: y)
            fail(
                "unauthorized palette color \(pixel.hex) at (\(x), \(y)): "
                    + "blend component is not a palette-edge transition"
            )
        }
    }
}

guard backgroundCount > 0, inkCount > 0, parchmentCount > 0 else {
    fail("approved palette interiors were not all present")
}
print("app-icon-validator: PASS: \(url.path)")
