#!/usr/bin/swift
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO

struct RGB: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
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
var backgroundCount = 0
var inkCount = 0
var parchmentCount = 0
let centerX = 512.0
let centerY = 512.0
let safeRadiusSquared = 471.04 * 471.04

for y in 0..<height {
    for x in 0..<width {
        let offset = (y * width + x) * 4
        let pixel = RGB(
            r: pixels[offset],
            g: pixels[offset + 1],
            b: pixels[offset + 2]
        )
        if pixel == background { backgroundCount += 1 }
        if pixel == ink { inkCount += 1 }
        if pixel == parchment { parchmentCount += 1 }

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
