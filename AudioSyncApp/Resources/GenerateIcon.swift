#!/usr/bin/env swift
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Generate a 1024x1024 app icon for AudioSync
// Design: Rounded rect with blue-purple gradient, 3 speakers in triangle, sound wave arcs

let size: CGFloat = 1024
let padding: CGFloat = 80
let cornerRadius: CGFloat = 220

// Create color space and context
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
) else {
    print("ERROR: Failed to create CGContext")
    exit(1)
}

// Flip coordinate system so (0,0) is bottom-left
context.translateBy(x: 0, y: size)
context.scaleBy(x: 1, y: -1)

// Draw rounded rect background with gradient
let rect = CGRect(x: padding, y: padding, width: size - 2 * padding, height: size - 2 * padding)
let clipPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

context.addPath(clipPath)
context.clip()

// Gradient: deep blue to purple
let gradientColors = [
    CGColor(red: 0.15, green: 0.18, blue: 0.55, alpha: 1.0),  // Deep blue
    CGColor(red: 0.45, green: 0.15, blue: 0.65, alpha: 1.0),  // Purple
] as CFArray
let gradientLocations: [CGFloat] = [0.0, 1.0]

guard let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: gradientLocations) else {
    print("ERROR: Failed to create gradient")
    exit(1)
}

context.drawLinearGradient(
    gradient,
    start: CGPoint(x: padding, y: padding),
    end: CGPoint(x: size - padding, y: size - padding),
    options: []
)

// Helper: draw a speaker icon (rectangle body + circle cone)
func drawSpeaker(at center: CGPoint, scale: CGFloat) {
    let bodyW: CGFloat = 60 * scale
    let bodyH: CGFloat = 80 * scale
    let coneR: CGFloat = 30 * scale

    // Speaker body (rounded rectangle)
    let bodyRect = CGRect(
        x: center.x - bodyW / 2,
        y: center.y - bodyH / 2,
        width: bodyW,
        height: bodyH
    )
    let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: 8 * scale, cornerHeight: 8 * scale, transform: nil)
    context.addPath(bodyPath)
    context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.9))
    context.fillPath()

    // Speaker cone (circle)
    let coneRect = CGRect(
        x: center.x - coneR,
        y: center.y - coneR,
        width: coneR * 2,
        height: coneR * 2
    )
    context.addEllipse(in: coneRect)
    context.setFillColor(CGColor(red: 0.2, green: 0.25, blue: 0.6, alpha: 1.0))
    context.fillPath()

    // Inner circle
    let innerR: CGFloat = 12 * scale
    let innerRect = CGRect(
        x: center.x - innerR,
        y: center.y - innerR,
        width: innerR * 2,
        height: innerR * 2
    )
    context.addEllipse(in: innerRect)
    context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.85))
    context.fillPath()
}

// Draw 3 speakers in a triangle/fan pattern
let centerX = size / 2
let centerY = size / 2 + 20

// Top speaker
drawSpeaker(at: CGPoint(x: centerX, y: centerY - 160), scale: 1.0)
// Bottom-left speaker
drawSpeaker(at: CGPoint(x: centerX - 180, y: centerY + 120), scale: 0.9)
// Bottom-right speaker
drawSpeaker(at: CGPoint(x: centerX + 180, y: centerY + 120), scale: 0.9)

// Draw sound wave arcs emanating from center
func drawSoundArc(radius: CGFloat, alpha: CGFloat) {
    let arcCenter = CGPoint(x: centerX, y: centerY - 20)
    let arcRect = CGRect(
        x: arcCenter.x - radius,
        y: arcCenter.y - radius,
        width: radius * 2,
        height: radius * 2
    )
    context.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: alpha))
    context.setLineWidth(4)
    context.addEllipse(in: arcRect)
    context.strokePath()
}

// Multiple concentric arcs
drawSoundArc(radius: 280, alpha: 0.35)
drawSoundArc(radius: 340, alpha: 0.25)
drawSoundArc(radius: 400, alpha: 0.15)

// Small highlight dots at speaker positions (glow effect)
func drawGlow(at center: CGPoint, radius: CGFloat) {
    let glowRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    context.addEllipse(in: glowRect)
    context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.08))
    context.fillPath()
}

drawGlow(at: CGPoint(x: centerX, y: centerY - 160), radius: 80)
drawGlow(at: CGPoint(x: centerX - 180, y: centerY + 120), radius: 70)
drawGlow(at: CGPoint(x: centerX + 180, y: centerY + 120), radius: 70)

// Save to PNG
guard let cgImage = context.makeImage() else {
    print("ERROR: Failed to create image from context")
    exit(1)
}

let outputPath = "Resources/AppIcon.png"
let outputURL = URL(fileURLWithPath: outputPath)

guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    print("ERROR: Failed to create image destination")
    exit(1)
}

CGImageDestinationAddImage(destination, cgImage, nil)
CGImageDestinationFinalize(destination)

print("✅ Icon generated: \(outputPath) (\(Int(size))x\(Int(size)))")
