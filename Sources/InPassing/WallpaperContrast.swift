import AppKit
import ImageIO
import InPassingCore

/// Reads the wallpaper file, never the screen or any application content.
@MainActor enum WallpaperContrast {
    struct Result { let color: NSColor; let sampled: Bool }

    static func outline(for screen: NSScreen) -> Result {
        let workspace = NSWorkspace.shared
        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        let background = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) ?? .black
        let wallpaperURL = workspace.desktopImageURL(for: screen)
        guard let url = wallpaperURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else {
            // macOS doesn't expose a current still image for every video/dynamic provider.
            if wallpaperURL == nil, options[.fillColor] != nil { return result(luminance: luminance(background)) }
            return Result(color: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black, sampled: false)
        }
        return sample(image, screenSize: screen.frame.size, options: options)
    }
    static func sample(_ image: CGImage, screenSize: CGSize, options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]) -> Result {
        let background = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) ?? .black
        let side = 64
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return Result(color: .white, sampled: false)
        }
        context.setFillColor(background.cgColor); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let imageAspect = Double(image.width) / Double(image.height)
        let screenAspect = screenSize.width / screenSize.height
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown
        var width = Double(side), height = Double(side)
        if scaling != .scaleAxesIndependently {
            let clip = options[.allowClipping] as? Bool ?? true
            if (imageAspect > screenAspect) == clip { width *= imageAspect / screenAspect }
            else { height *= screenAspect / imageAspect }
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height))
        var total = 0.0
        for index in 0..<(side * side) {
            total += linear(Double(bytes[index * 4]) / 255) * 0.2126
                   + linear(Double(bytes[index * 4 + 1]) / 255) * 0.7152
                   + linear(Double(bytes[index * 4 + 2]) / 255) * 0.0722
        }
        return result(luminance: total / Double(side * side))
    }
    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    private static func luminance(_ color: NSColor) -> Double {
        0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }
    private static func result(luminance: Double) -> Result {
        Result(color: prefersWhiteOutline(luminance: luminance) ? .white : .black, sampled: true)
    }
}
