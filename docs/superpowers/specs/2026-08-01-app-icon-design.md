# Burly App Icon Design

**Status:** Visual direction approved on 2026-08-01; written specification awaiting review.

## Purpose

Replace Burly's intentionally generic charcoal-and-white placeholder barbell
with a memorable identity for its iPhone and Apple Watch apps. The mark should
feel bold and characterful, identify strength training at a glance, and remain
clear in the Watch app grid.

This specification defines the design direction. It does not authorize or
describe the production asset implementation.

## Approved Direction: The Burly Strongman

The icon depicts a vintage strongman pressing a loaded barbell overhead. The
figure is front-facing, dramatically broad through the shoulders, and planted
in a wide triangular stance. The composition should feel triumphant and
larger-than-life rather than severe or technical.

The strongman is the brand's protagonist. The human figure supplies the memory
hook; the overhead barbell supplies the lifting-category cue. The mark is
symbolic and contains no letter `B`, wordmark, or other text.

## Visual Construction

- Use one flat, centered figure against a solid, edge-to-edge background.
- Build the strongman, arms, bar, and plates as one dominant Warm Ink
  silhouette.
- Use rounded bumper plates and a clean horizontal bar to give the mark a
  vintage weightlifting character without adding realistic equipment detail.
- Use a small Parchment singlet cut and handlebar-moustache cut as secondary
  character details. At the smallest rendered sizes these details may soften,
  but they must not merge into distracting noise.
- Keep the head, torso, arms, hands, bar, plates, and feet visually separable at
  small sizes. Do not draw individual muscles, facial anatomy, clothing seams,
  highlights, or shadows.
- Keep all critical silhouette geometry inside a circle centered on the canvas
  with a radius of `46%` of the master width. As starting construction guides,
  place the loaded bar no wider than `x = 14%...86%`, keep the highest plate
  pixel at or below `y = 23%`, keep the lowest foot pixel at or above `y = 88%`,
  and keep the outer foot edges within `x = 25%...75%`. Optical corrections are
  allowed only when the resulting silhouette still clears the `46%` circle.
- Do not bake a rounded-square or circular mask into the artwork.

The approved browser mockup is directional. Production geometry should preserve
its pose, proportions, palette, and character while correcting optical balance
and mask clearance at final sizes.

## Palette

| Role | Name | Value |
| --- | --- | --- |
| Background | Prizefighter Red | `#F04F2F` |
| Primary silhouette | Warm Ink | `#201713` |
| Small negative-space details | Parchment | `#FFF0CF` |

Use these as flat colors. The icon contains no gradients, texture, transparency,
glow, border, or baked-in drop shadow.

## Target Behavior

- Use the same master composition for the iPhone and Watch targets so the app
  has one identity across devices.
- Export each target's required `1024 x 1024` app-icon PNG from the same source
  artwork.
- Export as 8-bit RGB with no alpha channel, preserving the repository's
  existing App Store upload constraint.
- The two exported `AppIcon.png` files should be byte-identical when generated
  from the same toolchain.
- Treat Watch-size legibility as the stricter design constraint. Extra empty
  space on iPhone is preferable to clipped plates or an unreadable figure on
  Watch.

## Small-Size Acceptance

Review the production artwork at `180`, `120`, `60`, and `42` pixels square,
both as a rounded square and through a circular mask.

At every test size:

1. The first read is a person pressing a barbell overhead.
2. The bar remains horizontal and both ends read as loaded plates.
3. The figure's head, arms, torso, and wide stance remain distinct.
4. No plate, hand, foot, or other critical form appears clipped.
5. The singlet and moustache details either remain clean or soften harmlessly;
   neither may create stray-looking pixels.
6. The silhouette remains recognizable when viewed in grayscale.

## Production Deliverables

A future implementation should produce:

- editable source artwork committed to the repository;
- a deterministic export path that replaces the placeholder generator or
  evolves it into the production generator;
- matching no-alpha PNGs at the existing iPhone and Watch app-icon paths;
- small-size and mask-preview evidence for review; and
- validation that both targets still build with their existing asset-catalog
  configuration.

## Out of Scope

- redesigning the in-app UI or selecting a global app accent color;
- a wordmark, typography system, marketing illustration, or full brand guide;
- animated, seasonal, alternate, or user-selectable app icons;
- changing app-icon asset-catalog structure or deployment targets; and
- using the strongman as a mascot elsewhere in the product.

Those can be considered later, but they are not required to replace the current
placeholder icon.
