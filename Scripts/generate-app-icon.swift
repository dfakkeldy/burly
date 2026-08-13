#!/usr/bin/swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Generates Burly's production Strongman app icon. Regenerate both target
// assets from this source rather than editing their PNGs by hand.

import CoreGraphics
import Foundation
import ImageIO

let canvasSize = 1024
let prizefighterRed = (r: 0xF0, g: 0x4F, b: 0x2F)
let warmInk = (r: 0x20, g: 0x17, b: 0x13)
let parchment = (r: 0xFF, g: 0xF0, b: 0xCF)

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        "Usage: swift generate-app-icon.swift <output.png>\n".data(using: .utf8)!
    )
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let colorSpace = CGColorSpaceCreateDeviceRGB()
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

context.translateBy(x: 0, y: CGFloat(canvasSize))
context.scaleBy(x: 1, y: -1)

func setFill(_ context: CGContext, _ color: (r: Int, g: Int, b: Int)) {
    context.setFillColor(
        red: CGFloat(color.r) / 255,
        green: CGFloat(color.g) / 255,
        blue: CGFloat(color.b) / 255,
        alpha: 1
    )
}

func fillRoundedRect(
    _ rect: CGRect,
    radius: CGFloat,
    color: (r: Int, g: Int, b: Int)
) {
    setFill(context, color)
    context.addPath(CGPath(
        roundedRect: rect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    ))
    context.fillPath()
}

func fillEllipse(_ rect: CGRect, color: (r: Int, g: Int, b: Int)) {
    setFill(context, color)
    context.fillEllipse(in: rect)
}

func stroke(_ path: CGPath, width: CGFloat, color: (r: Int, g: Int, b: Int)) {
    context.addPath(path)
    context.setStrokeColor(
        red: CGFloat(color.r) / 255,
        green: CGFloat(color.g) / 255,
        blue: CGFloat(color.b) / 255,
        alpha: 1
    )
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
}

setFill(context, prizefighterRed)
context.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

// Loaded bar: x=14%...86%, top=23%; all corners clear the 46% safe circle.
fillRoundedRect(CGRect(x: 143, y: 274, width: 738, height: 24), radius: 12, color: warmInk)
fillRoundedRect(CGRect(x: 143, y: 235, width: 80, height: 102), radius: 24, color: warmInk)
fillRoundedRect(CGRect(x: 801, y: 235, width: 80, height: 102), radius: 24, color: warmInk)
fillRoundedRect(CGRect(x: 223, y: 252, width: 42, height: 68), radius: 16, color: warmInk)
fillRoundedRect(CGRect(x: 759, y: 252, width: 42, height: 68), radius: 16, color: warmInk)

fillEllipse(CGRect(x: 324, y: 249, width: 76, height: 76), color: warmInk)
fillEllipse(CGRect(x: 624, y: 249, width: 76, height: 76), color: warmInk)

let leftArm = CGMutablePath()
leftArm.move(to: CGPoint(x: 362, y: 294))
leftArm.addLine(to: CGPoint(x: 432, y: 525))
stroke(leftArm, width: 92, color: warmInk)

let rightArm = CGMutablePath()
rightArm.move(to: CGPoint(x: 662, y: 294))
rightArm.addLine(to: CGPoint(x: 592, y: 525))
stroke(rightArm, width: 92, color: warmInk)

fillEllipse(CGRect(x: 447, y: 365, width: 130, height: 130), color: warmInk)
fillRoundedRect(CGRect(x: 478, y: 470, width: 68, height: 80), radius: 24, color: warmInk)

let body = CGMutablePath()
body.move(to: CGPoint(x: 418, y: 500))
body.addCurve(
    to: CGPoint(x: 355, y: 708),
    control1: CGPoint(x: 360, y: 540),
    control2: CGPoint(x: 340, y: 620)
)
body.addLine(to: CGPoint(x: 265, y: 900))
body.addLine(to: CGPoint(x: 443, y: 900))
body.addLine(to: CGPoint(x: 512, y: 720))
body.addLine(to: CGPoint(x: 581, y: 900))
body.addLine(to: CGPoint(x: 759, y: 900))
body.addLine(to: CGPoint(x: 669, y: 708))
body.addCurve(
    to: CGPoint(x: 606, y: 500),
    control1: CGPoint(x: 684, y: 620),
    control2: CGPoint(x: 664, y: 540)
)
body.addQuadCurve(to: CGPoint(x: 418, y: 500), control: CGPoint(x: 512, y: 575))
body.closeSubpath()
setFill(context, warmInk)
context.addPath(body)
context.fillPath()

let singlet = CGMutablePath()
singlet.move(to: CGPoint(x: 410, y: 515))
singlet.addCurve(
    to: CGPoint(x: 614, y: 515),
    control1: CGPoint(x: 450, y: 625),
    control2: CGPoint(x: 574, y: 625)
)
singlet.addLine(to: CGPoint(x: 648, y: 600))
singlet.addCurve(
    to: CGPoint(x: 376, y: 600),
    control1: CGPoint(x: 570, y: 700),
    control2: CGPoint(x: 454, y: 700)
)
singlet.closeSubpath()
setFill(context, parchment)
context.addPath(singlet)
context.fillPath()

let moustache = CGMutablePath()
moustache.move(to: CGPoint(x: 465, y: 438))
moustache.addCurve(
    to: CGPoint(x: 512, y: 442),
    control1: CGPoint(x: 482, y: 462),
    control2: CGPoint(x: 499, y: 454)
)
moustache.addCurve(
    to: CGPoint(x: 559, y: 438),
    control1: CGPoint(x: 525, y: 454),
    control2: CGPoint(x: 542, y: 462)
)
stroke(moustache, width: 18, color: parchment)

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

print("Wrote \(outputPath) (1024x1024 RGB, no alpha, Burly Strongman)")
