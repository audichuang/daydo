#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let iosDir = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let assetsDir = iosDir.appendingPathComponent("DayDo/Resources/Assets.xcassets")
let sourceURL = assetsDir.appendingPathComponent("AppIcon.appiconset/icon-1024-dark.png")
let outputDir = assetsDir.appendingPathComponent("LaunchLogo.imageset")

guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fputs("Failed to load source image at \(sourceURL.path)\n", stderr)
    exit(1)
}

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
let sizes: [(scale: String, px: Int, filename: String)] = [
    ("1x", 120, "LaunchLogo-1x.png"),
    ("2x", 240, "LaunchLogo-2x.png"),
    ("3x", 360, "LaunchLogo-3x.png"),
]

for entry in sizes {
    let px = entry.px
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        fputs("Failed to create CGContext for \(px)px\n", stderr)
        exit(1)
    }

    let rect = CGRect(x: 0, y: 0, width: px, height: px)
    let radius = CGFloat(px) * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.clear(rect)
    ctx.interpolationQuality = .high
    ctx.addPath(path)
    ctx.clip()
    ctx.draw(sourceImage, in: rect)

    guard let outImage = ctx.makeImage() else {
        fputs("Failed to create output CGImage for \(px)px\n", stderr)
        exit(1)
    }

    let outURL = outputDir.appendingPathComponent(entry.filename)
    guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fputs("Failed to create image destination at \(outURL.path)\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(dest, outImage, nil)
    guard CGImageDestinationFinalize(dest) else {
        fputs("Failed to write PNG at \(outURL.path)\n", stderr)
        exit(1)
    }
}

let contents = """
{
  "images" : [
    {
      "filename" : "LaunchLogo-1x.png",
      "idiom" : "universal",
      "scale" : "1x"
    },
    {
      "filename" : "LaunchLogo-2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    },
    {
      "filename" : "LaunchLogo-3x.png",
      "idiom" : "universal",
      "scale" : "3x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try contents.write(to: outputDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Generated LaunchLogo.imageset at \(outputDir.path)")
