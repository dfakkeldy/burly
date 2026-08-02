#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$REPO_ROOT/Scripts/generate-app-icon.swift"
VALIDATOR="$REPO_ROOT/Scripts/validate-app-icon.swift"
PHONE_ICON="$REPO_ROOT/BurlyPhone/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
WATCH_ICON="$REPO_ROOT/BurlyWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
TEST_DIR="$(mktemp -d -t burly-app-icon-test)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  echo "app-icon-test: FAIL: $*" >&2
  exit 1
}

[[ -f "$GENERATOR" ]] || fail "missing generator: $GENERATOR"
[[ -f "$VALIDATOR" ]] || fail "missing validator: $VALIDATOR"

swift "$GENERATOR" "$TEST_DIR/first.png"
swift "$GENERATOR" "$TEST_DIR/second.png"

cmp -s "$TEST_DIR/first.png" "$TEST_DIR/second.png" \
  || fail "two fresh generations differ"
cmp -s "$TEST_DIR/first.png" "$PHONE_ICON" \
  || fail "iPhone AppIcon.png is stale"
cmp -s "$TEST_DIR/first.png" "$WATCH_ICON" \
  || fail "Watch AppIcon.png is stale"

for icon in "$TEST_DIR/first.png" "$PHONE_ICON" "$WATCH_ICON"; do
  swift "$VALIDATOR" "$icon"
  file "$icon" | grep -q 'PNG image data, 1024 x 1024, 8-bit/color RGB' \
    || fail "$icon is not a 1024x1024 8-bit RGB PNG"
done

swift - \
  "$TEST_DIR/first.png" \
  "$TEST_DIR/unauthorized-palette.png" \
  "$TEST_DIR/interior-blend.png" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Could not read palette fixture source")
}

func writeFixture(path: String, color: (red: CGFloat, green: CGFloat, blue: CGFloat)) {
    guard let context = CGContext(
          data: nil,
          width: image.width,
          height: image.height,
          bitsPerComponent: 8,
          bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        fatalError("Could not prepare palette fixture")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.setFillColor(
        red: color.red,
        green: color.green,
        blue: color.blue,
        alpha: 1
    )
    context.fill(CGRect(x: 496, y: 496, width: 32, height: 32))
    let outputURL = URL(fileURLWithPath: path)
    guard let fixture = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              outputURL as CFURL,
              "public.png" as CFString,
              1,
              nil
          ) else {
        fatalError("Could not create palette fixture")
    }
    CGImageDestinationAddImage(destination, fixture, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not write palette fixture")
    }
}

writeFixture(path: CommandLine.arguments[2], color: (0, 0x70 / 255, 1))
writeFixture(path: CommandLine.arguments[3], color: (0x88 / 255, 0x33 / 255, 0x21 / 255))
SWIFT

expect_palette_rejection() {
  local fixture="$1"
  local expected_color="$2"
  local log="$fixture.log"
  if swift "$VALIDATOR" "$fixture" >"$log" 2>&1; then
    fail "validator accepted unauthorized interior color $expected_color"
  fi
  grep -q "FAIL: unauthorized palette color $expected_color" "$log" \
    || fail "palette fixture failed for the wrong reason: $fixture"
  cat "$log"
}

expect_palette_rejection "$TEST_DIR/unauthorized-palette.png" '#0070FF'
expect_palette_rejection "$TEST_DIR/interior-blend.png" '#883321'

echo "app-icon-test: PASS"
