#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

let fileManager = FileManager.default
let scriptUrl = URL(fileURLWithPath: CommandLine.arguments[0]).standardized
let projectDir = scriptUrl.deletingLastPathComponent().deletingLastPathComponent()

let defaultInputPath = projectDir.appendingPathComponent("packaging/AppLogo.png").path
let fallbackUserUpload = "/Users/harry/.gemini/antigravity-ide/brain/e8b49ce8-25fc-485b-9385-826ded205870/.user_uploaded/media_1786679270114.jpg"
let inputSourcePath: String
if CommandLine.arguments.count > 1 {
    inputSourcePath = CommandLine.arguments[1]
} else if fileManager.fileExists(atPath: fallbackUserUpload) {
    inputSourcePath = fallbackUserUpload
} else {
    inputSourcePath = defaultInputPath
}

guard let sourceImg = NSImage(contentsOfFile: inputSourcePath),
      let srcCG = sourceImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Error: Could not load source image from \(inputSourcePath)\n", stderr)
    exit(1)
}

print("Loaded source image: \(srcCG.width)x\(srcCG.height)")

// macOS Standard App Icon Specifications:
// Canvas: 1024 x 1024
// Squircle dimensions: 824 x 824
// Continuous corner radius: 185 px (~0.224 ratio)
// Centered: (100, 100) on 1024x1024 canvas
func createMasterAppIcon(source: CGImage) -> CGImage {
    let canvasSize: CGFloat = 1024
    let iconSize: CGFloat = 824
    let iconX: CGFloat = (canvasSize - iconSize) / 2.0 // 100
    let iconY: CGFloat = 100.0 // CG bottom-left origin

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: nil,
                              width: Int(canvasSize),
                              height: Int(canvasSize),
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: bitmapInfo) else {
        fatalError("Failed to create CGContext")
    }

    ctx.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

    let iconRect = CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
    let cornerRadius: CGFloat = 185.0

    let squirclePath = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // 1. macOS HIG Drop Shadows
    // Key shadow (ambient soft shadow)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 30, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.36))
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Contact shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.20))
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Icon Content (Clipped to Squircle)
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    // Base background color
    ctx.setFillColor(CGColor(red: 0.14, green: 0.14, blue: 0.14, alpha: 1.0))
    ctx.fill(iconRect)

    // Crop source squircle region (measured cleanly from user input image)
    // Source crop rect in CG coordinates (y=0 at bottom):
    // Source dimensions: 1024x1024, dark squircle is at x:84..940, top:66..938 -> CG y: 88, h: 848
    let srcCropRect = CGRect(x: 84, y: 88, width: 856, height: 848)
    if let cropped = source.cropping(to: srcCropRect) {
        let drawRect = iconRect.insetBy(dx: -2, dy: -2)
        ctx.draw(cropped, in: drawRect)
    }
    ctx.restoreGState()

    // 3. Apple HIG macOS Icon Edge Rim Highlight
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.setLineWidth(1.5)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.16))
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

// Function to create tight-cropped squircle icon (without canvas shadow padding)
func createTightAppLogo(source: CGImage, size: Int = 512) -> CGImage {
    let s = CGFloat(size)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: nil,
                              width: size,
                              height: size,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: bitmapInfo) else {
        fatalError("Failed to create CGContext")
    }

    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let radius = s * 0.2244 // Apple continuous corner ratio
    let squirclePath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    ctx.setFillColor(CGColor(red: 0.14, green: 0.14, blue: 0.14, alpha: 1.0))
    ctx.fill(rect)

    let srcCropRect = CGRect(x: 84, y: 88, width: 856, height: 848)
    if let cropped = source.cropping(to: srcCropRect) {
        let drawRect = rect.insetBy(dx: -1, dy: -1)
        ctx.draw(cropped, in: drawRect)
    }
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.setLineWidth(s >= 128 ? 1.5 : 1.0)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.16))
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func resizeImage(image: CGImage, targetWidth: Int, targetHeight: Int) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: nil,
                              width: targetWidth,
                              height: targetHeight,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: bitmapInfo) else {
        fatalError("Failed to create CGContext for resizing")
    }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    return ctx.makeImage()!
}

func savePNG(image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PNGConversion", code: 1, userInfo: nil)
    }
    try pngData.write(to: url)
}

let packagingDir = projectDir.appendingPathComponent("packaging")
let iconsetDir = packagingDir.appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(at: iconsetDir)
try fileManager.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let master1024 = createMasterAppIcon(source: srcCG)
let tight512 = createTightAppLogo(source: srcCG, size: 512)

// Standard macOS iconset specification
let iconSizes: [(name: String, pixelSize: Int)] = [
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

print("Generating iconset PNG files...")
for item in iconSizes {
    let resized: CGImage
    if item.pixelSize == 1024 {
        resized = master1024
    } else {
        resized = resizeImage(image: master1024, targetWidth: item.pixelSize, targetHeight: item.pixelSize)
    }
    let fileUrl = iconsetDir.appendingPathComponent(item.name)
    try savePNG(image: resized, to: fileUrl)
    print("  -> \(item.name) (\(item.pixelSize)x\(item.pixelSize))")
}

// Save standalone master PNGs
let appLogoUrl = packagingDir.appendingPathComponent("AppLogo.png")
try savePNG(image: master1024, to: appLogoUrl)
print("Saved \(appLogoUrl.path)")

let tightLogoUrl = packagingDir.appendingPathComponent("AppLogo-tight.png")
try savePNG(image: tight512, to: tightLogoUrl)
print("Saved \(tightLogoUrl.path)")

// Run iconutil to create AppIcon.icns
let icnsUrl = packagingDir.appendingPathComponent("AppIcon.icns")
let iconutilProcess = Process()
iconutilProcess.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutilProcess.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsUrl.path]
try iconutilProcess.run()
iconutilProcess.waitUntilExit()

if iconutilProcess.terminationStatus == 0 {
    print("Successfully generated AppIcon.icns at \(icnsUrl.path)")
} else {
    fputs("Error: iconutil failed with status \(iconutilProcess.terminationStatus)\n", stderr)
    exit(Int32(iconutilProcess.terminationStatus))
}
