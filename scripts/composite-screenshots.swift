#!/usr/bin/env swift
// Composites UI test window captures onto a desktop wallpaper.
// Usage: swift composite-screenshots.swift <resources-dir> <screenshots-dir>
//
// <resources-dir>: Desktop-Sequoia.png, Fullscreen-Code.png
// <screenshots-dir>: helper-window.png, helper-window-code.png, helper-window-terminal.png
//   (captured with hasShadow=false — tight to window frame, real GhostVM toolbar)
//
// Outputs to <screenshots-dir>:
//   hero-screenshot.png, multiple-vms.png, vm-integration.png

import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("Usage: \(args[0]) <resources-dir> <screenshots-dir>\n", stderr)
    exit(1)
}

let resourcesDir = args[1]
let screenshotsDir = args[2]

func loadImage(_ dir: String, _ name: String) -> NSImage {
    let path = "\(dir)/\(name)"
    guard let image = NSImage(contentsOfFile: path) else {
        fputs("Failed to load \(path)\n", stderr)
        exit(1)
    }
    return image
}

let desktop = loadImage(resourcesDir, "Desktop-Sequoia.png")
let windowClean = loadImage(screenshotsDir, "helper-window.png")
let windowCode = loadImage(screenshotsDir, "helper-window-code.png")
let windowTerminal = loadImage(screenshotsDir, "helper-window-terminal.png")
let fullscreenCode = loadImage(resourcesDir, "Fullscreen-Code.png")

let desktopW = 2992
let desktopH = 1934

func pixelSize(_ img: NSImage) -> (Int, Int) {
    guard let rep = img.representations.first else { return (0, 0) }
    return (rep.pixelsWide, rep.pixelsHigh)
}

func savePNG(_ image: NSImage, to filename: String) {
    let path = "\(screenshotsDir)/\(filename)"
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fputs("Failed to create PNG for \(filename)\n", stderr)
        exit(1)
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("Saved \(path) (\(png.count / 1024)KB)")
    } catch {
        fputs("Failed to write \(path): \(error)\n", stderr)
        exit(1)
    }
}

func fitSize(_ imgW: Int, _ imgH: Int, _ slotW: Int, _ slotH: Int) -> (Int, Int) {
    let scale = min(Double(slotW) / Double(imgW), Double(slotH) / Double(imgH))
    return (Int(Double(imgW) * scale), Int(Double(imgH) * scale))
}

/// macOS window corner radius at @2x
let cornerRadius: CGFloat = 20

/// Draws a window image with a drop shadow and rounded-corner mask.
/// The captured images (hasShadow=false) are tight to the window frame but still
/// rectangular PNGs — the corner pixels show test background. We clip to a rounded
/// rect to clean up the corners, then use CG shadow for the drop shadow.
func drawWindow(_ image: NSImage, at rect: NSRect, context: CGContext) {
    // 1. Draw shadow: fill a rounded rect while shadow is active
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 30,
                      color: CGColor(gray: 0, alpha: 0.45))
    let shadowPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    context.addPath(shadowPath)
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // 2. Clip to rounded rect and draw the actual window image on top
    context.saveGState()
    let clipPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    context.addPath(clipPath)
    context.clip()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    context.restoreGState()
}

// --- Hero: clean VM window (no app, just guest desktop) centered ---
func generateHero() -> NSImage {
    let canvas = NSImage(size: NSSize(width: desktopW, height: desktopH))
    canvas.lockFocus()
    let context = NSGraphicsContext.current!.cgContext

    desktop.draw(in: NSRect(x: 0, y: 0, width: desktopW, height: desktopH))

    let (w, h) = pixelSize(windowClean)
    let (fitW, fitH) = fitSize(w, h, Int(Double(desktopW) * 0.82), Int(Double(desktopH) * 0.85))
    let x = (desktopW - fitW) / 2
    let y = (desktopH - fitH) / 2 - 10

    drawWindow(windowClean, at: NSRect(x: x, y: y, width: fitW, height: fitH), context: context)

    canvas.unlockFocus()
    return canvas
}

// --- Code VM: Fullscreen-Code.png already has native macOS shadow + rounded corners via alpha ---
func generateCodeVM() -> NSImage {
    let canvas = NSImage(size: NSSize(width: desktopW, height: desktopH))
    canvas.lockFocus()

    desktop.draw(in: NSRect(x: 0, y: 0, width: desktopW, height: desktopH))

    let (w, h) = pixelSize(fullscreenCode)
    let (fitW, fitH) = fitSize(w, h, Int(Double(desktopW) * 0.82), Int(Double(desktopH) * 0.85))
    let x = (desktopW - fitW) / 2
    let y = (desktopH - fitH) / 2 - 10

    fullscreenCode.draw(in: NSRect(x: x, y: y, width: fitW, height: fitH),
                        from: .zero, operation: .sourceOver, fraction: 1.0)

    canvas.unlockFocus()
    return canvas
}

// --- Integration: layered windows ---
func generateIntegration() -> NSImage {
    let canvas = NSImage(size: NSSize(width: desktopW, height: desktopH))
    canvas.lockFocus()
    let context = NSGraphicsContext.current!.cgContext

    desktop.draw(in: NSRect(x: 0, y: 0, width: desktopW, height: desktopH))

    let (tw, th) = pixelSize(windowTerminal)
    let (fitTW, fitTH) = fitSize(tw, th, Int(Double(desktopW) * 0.52), Int(Double(desktopH) * 0.65))
    drawWindow(windowTerminal,
               at: NSRect(x: 70, y: desktopH - fitTH - 90, width: fitTW, height: fitTH),
               context: context)

    let (cw, ch) = pixelSize(windowCode)
    let (fitCW, fitCH) = fitSize(cw, ch, Int(Double(desktopW) * 0.68), Int(Double(desktopH) * 0.75))
    drawWindow(windowCode,
               at: NSRect(x: desktopW - fitCW - 70, y: 50, width: fitCW, height: fitCH),
               context: context)

    canvas.unlockFocus()
    return canvas
}

print("Generating hero...")
savePNG(generateHero(), to: "hero-screenshot.png")
print("Generating integration...")
savePNG(generateIntegration(), to: "multiple-vms.png")
print("Generating code VM...")
savePNG(generateCodeVM(), to: "vm-integration.png")
print("Done!")
