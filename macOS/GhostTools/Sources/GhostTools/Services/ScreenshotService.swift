import AppKit
import CoreGraphics
import CoreText

/// Guest-side screenshot capture service.
/// Always captures the full display.
final class ScreenshotService {
    static let shared = ScreenshotService()
    private init() {}

    enum CaptureError: Error, LocalizedError {
        case captureFailed
        case screenRecordingDenied

        var errorDescription: String? {
            switch self {
            case .captureFailed: return "Screenshot capture failed"
            case .screenRecordingDenied: return "Screen Recording permission required"
            }
        }
    }

    func captureRawCGImage() throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.screenRecordingDenied
        }

        if let image = CGDisplayCreateImage(CGMainDisplayID()) {
            return image
        }

        throw CaptureError.captureFailed
    }

    func capturePNG() throws -> Data {
        let cgImage = try captureRawCGImage()
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError.captureFailed
        }
        return data
    }

    func captureJPEG(scale: Double = 1.0, quality: Double = 0.8) throws -> Data {
        let cgImage = try captureRawCGImage()

        let width = max(1, Int(Double(cgImage.width) * scale))
        let height = max(1, Int(Double(cgImage.height) * scale))

        let imageForEncoding: CGImage
        if scale < 1.0 {
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                throw CaptureError.captureFailed
            }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else {
                throw CaptureError.captureFailed
            }
            imageForEncoding = scaled
        } else {
            imageForEncoding = cgImage
        }

        let rep = NSBitmapImageRep(cgImage: imageForEncoding)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw CaptureError.captureFailed
        }
        return data
    }

    func captureJPEGBase64(scale: Double = 0.5, quality: Double = 0.7) -> String? {
        guard let data = try? captureJPEG(scale: scale, quality: quality) else { return nil }
        return data.base64EncodedString()
    }

    /// Annotates a full-screen screenshot with accessibility element overlays.
    /// Element frames are screen-absolute; screenshot origin is (0,0).
    /// When `changeAges` is provided, elements are colored by recency:
    /// green (age 0), orange (age 1), dim red (age 2+). Nil uses uniform red.
    func annotateWithElements(
        _ image: CGImage,
        elements: [AccessibilityService.InteractiveElement],
        changeAges: [Int: Int]? = nil
    ) -> CGImage? {
        guard !elements.isEmpty else { return image }

        let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let width = image.width
        let height = image.height

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        // Draw base image
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Flip to top-left origin for screen-coordinate overlay drawing
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)

        let lineWidth = 1.5 * backingScale
        let badgeDiameter = 16.0 * backingScale
        context.setLineWidth(lineWidth)

        // Draw each element
        for element in elements {
            let (strokeColor, fillColor, badgeColor) = Self.colorsForAge(
                changeAges?[element.id]
            )

            // Elements are screen-absolute, screenshot is full display at origin (0,0)
            let pixelX = element.frame.x * backingScale
            let pixelY = element.frame.y * backingScale
            let pixelW = element.frame.width * backingScale
            let pixelH = element.frame.height * backingScale

            // Skip elements outside screenshot bounds
            guard pixelX >= -pixelW && pixelX < Double(width) &&
                  pixelY >= -pixelH && pixelY < Double(height) else {
                continue
            }

            // Draw bounding box with minimum 2px size
            let boxRect = CGRect(
                x: pixelX,
                y: pixelY,
                width: max(2 * backingScale, pixelW),
                height: max(2 * backingScale, pixelH)
            )

            context.setStrokeColor(strokeColor)
            context.setFillColor(fillColor)
            context.fill(boxRect)
            context.stroke(boxRect)

            // Draw badge circle at top-left corner
            let badgeRect = CGRect(
                x: pixelX - badgeDiameter / 2,
                y: pixelY - badgeDiameter / 2,
                width: badgeDiameter,
                height: badgeDiameter
            )

            context.setFillColor(badgeColor)
            context.fillEllipse(in: badgeRect)

            // Draw badge number
            drawBadgeNumber(element.id, in: badgeRect, context: context, scale: backingScale)
        }

        return context.makeImage()
    }

    /// Returns (stroke, fill, badge) colors based on changeAge.
    /// nil age falls back to uniform red (backward compat).
    static func colorsForAge(_ age: Int?) -> (stroke: CGColor, fill: CGColor, badge: CGColor) {
        guard let age else {
            // Default uniform red
            return (
                CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.8),
                CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.05),
                CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.85)
            )
        }
        switch age {
        case 0: // Hot — green
            return (
                CGColor(red: 0.0, green: 0.8, blue: 0.0, alpha: 0.9),
                CGColor(red: 0.0, green: 0.8, blue: 0.0, alpha: 0.08),
                CGColor(red: 0.0, green: 0.7, blue: 0.0, alpha: 0.9)
            )
        case 1: // Warm — orange
            return (
                CGColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 0.8),
                CGColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 0.05),
                CGColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.85)
            )
        default: // Cold — dim red
            return (
                CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.4),
                CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.02),
                CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.45)
            )
        }
    }

    // MARK: - Private

    private func drawBadgeNumber(_ number: Int, in rect: CGRect, context: CGContext, scale: Double) {
        let fontSize = 10.0 * scale
        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let text = "\(number)"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]

        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)

        // Get text bounds for centering
        let textBounds = CTLineGetBoundsWithOptions(line, [])
        let textWidth = textBounds.width
        let textHeight = textBounds.height

        // Calculate centered position
        let centerX = rect.midX - textWidth / 2
        let centerY = rect.midY - textHeight / 2

        // Save context state
        context.saveGState()

        // Move to text position and flip coordinate system for text rendering
        context.textMatrix = .identity
        context.translateBy(x: centerX, y: centerY + textHeight)
        context.scaleBy(x: 1.0, y: -1.0)

        // Draw the text
        CTLineDraw(line, context)

        // Restore context state
        context.restoreGState()
    }

}
